-- Record of Employment (ROE) on file (George, Nov 14: "we can also have a spot to add that for employees when we did give it to them,
-- at least it is now noted on why no more cheques and they move to past"). Read from the ROE PDF in the browser; the SIN is covered on the
-- page picture before it is saved and is never kept. Saving one sets the person's last day to block 11 (the last day paid, or their final cheque
-- if it came later) when there is no other cheque for them after it, so they move to Past employees; the pay history says why the cheques stopped. Owners only.
CREATE TABLE IF NOT EXISTS public.payroll_roe (
  id bigserial PRIMARY KEY, staff_id bigint NOT NULL REFERENCES public.payroll_staff(id) ON DELETE CASCADE,
  serial text, first_day date, last_paid date NOT NULL, final_end date, reason_code text, reason text, occupation text,
  hours numeric(10,2), earnings numeric(12,2), issued_on date, slip_name text, page_path text, file_name text, note text,
  loaded_by text, loaded_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX IF NOT EXISTS payroll_roe_one ON public.payroll_roe (staff_id, last_paid);
ALTER TABLE public.payroll_roe ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_roe FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._roe_reason(c text) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE upper(btrim(coalesce(c, ''))) WHEN 'A' THEN 'Shortage of work / end of contract or season' WHEN 'B' THEN 'Strike or lockout'
    WHEN 'D' THEN 'Illness or injury' WHEN 'E' THEN 'Quit' WHEN 'F' THEN 'Maternity' WHEN 'G' THEN 'Mandatory retirement' WHEN 'H' THEN 'Work-sharing'
    WHEN 'J' THEN 'Apprentice training' WHEN 'K' THEN 'Other' WHEN 'M' THEN 'Dismissal or suspension' WHEN 'N' THEN 'Leave of absence'
    WHEN 'P' THEN 'Parental' WHEN 'Z' THEN 'Compassionate care / family caregiver' END $f$;

-- the last day set by the newest ROE that has no cheque after it (30 days of room for the last cheque of the final pay)
CREATE OR REPLACE FUNCTION public._roe_left_on(p_staff bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE r payroll_roe; lo date;
BEGIN
  SELECT * INTO r FROM payroll_roe WHERE staff_id = p_staff ORDER BY last_paid DESC LIMIT 1;
  IF NOT FOUND THEN RETURN; END IF;
  IF NOT EXISTS (SELECT 1 FROM payroll_slips z WHERE z.staff_id = p_staff AND z.cheque_date > coalesce(r.final_end, r.last_paid) + 30) THEN
    -- the final cheque usually comes after the last day paid: the last day is that cheque's date, so the person is in Past employees
    lo := greatest(r.last_paid, (SELECT max(z.cheque_date) FROM payroll_slips z WHERE z.staff_id = p_staff AND z.cheque_date <= coalesce(r.final_end, r.last_paid) + 30));
    UPDATE payroll_staff SET left_on = lo, updated_at = now() WHERE id = p_staff AND left_on IS DISTINCT FROM lo;
  END IF;
END $f$;

CREATE OR REPLACE FUNCTION public.payroll_roe_save(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE x jsonb; sid bigint; n int := 0; who text := public._staff_name(public.current_app_user_id()); nm text; lp date; ids bigint[] := '{}';
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can load an ROE'; END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p -> 'roes', '[]'::jsonb)) LOOP
    nm := btrim(coalesce(x ->> 'name', ''));
    lp := nullif(x ->> 'last_paid', '')::date;
    IF lp IS NULL THEN RAISE EXCEPTION 'The ROE of % has no last day paid (block 11)', coalesce(nullif(nm, ''), '?'); END IF;
    sid := public._payroll_staff_for(nullif(x ->> 'staff', '')::bigint, nullif(x ->> 'user', '')::bigint, nm, x ->> 'block');
    IF sid IS NULL THEN RAISE EXCEPTION 'Who is the ROE of %?', coalesce(nullif(nm, ''), '?'); END IF;
    UPDATE payroll_staff SET aliases = CASE WHEN nm = '' OR lower(nm) = ANY (SELECT lower(a) FROM unnest(aliases) a) OR lower(name) = lower(nm) THEN aliases ELSE aliases || nm END WHERE id = sid;
    INSERT INTO payroll_roe (staff_id, serial, first_day, last_paid, final_end, reason_code, reason, occupation, hours, earnings, issued_on, slip_name, page_path, file_name, loaded_by)
      VALUES (sid, nullif(btrim(x ->> 'serial'), ''), nullif(x ->> 'first_day', '')::date, lp, nullif(x ->> 'final_end', '')::date,
        upper(nullif(btrim(x ->> 'reason_code'), '')), coalesce(nullif(btrim(x ->> 'reason'), ''), public._roe_reason(x ->> 'reason_code')),
        nullif(btrim(x ->> 'occupation'), ''), nullif(x ->> 'hours', '')::numeric, nullif(x ->> 'earnings', '')::numeric, nullif(x ->> 'issued_on', '')::date,
        nullif(nm, ''), nullif(x ->> 'page', ''), p ->> 'file', who)
      ON CONFLICT (staff_id, last_paid) DO UPDATE SET serial = EXCLUDED.serial, first_day = EXCLUDED.first_day, final_end = EXCLUDED.final_end,
        reason_code = EXCLUDED.reason_code, reason = EXCLUDED.reason, occupation = EXCLUDED.occupation, hours = EXCLUDED.hours, earnings = EXCLUDED.earnings,
        issued_on = EXCLUDED.issued_on, slip_name = EXCLUDED.slip_name, page_path = coalesce(EXCLUDED.page_path, payroll_roe.page_path),
        file_name = EXCLUDED.file_name, loaded_by = EXCLUDED.loaded_by, loaded_at = now();
    ids := ids || sid; n := n + 1;
  END LOOP;
  FOR sid IN SELECT DISTINCT unnest(ids) LOOP PERFORM public._roe_left_on(sid); PERFORM public._payroll_staff_refresh(sid); END LOOP;
  RETURN jsonb_build_object('saved', n);
END $f$;

CREATE OR REPLACE FUNCTION public.payroll_roe_del(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE r payroll_roe;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  SELECT * INTO r FROM payroll_roe WHERE id = p_id; IF NOT FOUND THEN RETURN; END IF;
  DELETE FROM payroll_roe WHERE id = p_id;
  -- the last day it set goes with it (a last day typed by hand on another day stays)
  UPDATE payroll_staff SET left_on = NULL, updated_at = now() WHERE id = r.staff_id AND left_on BETWEEN r.last_paid AND coalesce(r.final_end, r.last_paid) + 30;
  PERFORM public._roe_left_on(r.staff_id);
  PERFORM public._payroll_staff_refresh(r.staff_id);
END $f$;

CREATE OR REPLACE FUNCTION public.payroll_roe_list(p_staff bigint DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._src_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'staff', ps.id, 'user', ps.app_user_id,
      'name', coalesce(r.slip_name, ps.name), 'serial', r.serial, 'first_day', r.first_day, 'last_paid', r.last_paid, 'final_end', r.final_end,
      'code', r.reason_code, 'reason', r.reason, 'occupation', r.occupation, 'hours', r.hours, 'earnings', r.earnings, 'issued', r.issued_on,
      'page', r.page_path, 'by', r.loaded_by, 'at', r.loaded_at,
      'later', EXISTS (SELECT 1 FROM payroll_slips z WHERE z.staff_id = r.staff_id AND z.cheque_date > coalesce(r.final_end, r.last_paid) + 30))
      ORDER BY r.last_paid DESC)
    FROM payroll_roe r JOIN payroll_staff ps ON ps.id = r.staff_id WHERE p_staff IS NULL OR r.staff_id = p_staff), '[]'::jsonb) ELSE '[]'::jsonb END $f$;

REVOKE EXECUTE ON FUNCTION public._roe_left_on(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_roe_save(jsonb), public.payroll_roe_del(bigint), public.payroll_roe_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_roe_save(jsonb), public.payroll_roe_del(bigint), public.payroll_roe_list(bigint) TO authenticated;
-- the pay history is written again for the people with an ROE (282's refresh writes the ROE lines)
DO $do$ DECLARE r record; BEGIN FOR r IN SELECT DISTINCT staff_id FROM public.payroll_roe LOOP PERFORM public._payroll_staff_refresh(r.staff_id); END LOOP; END $do$;
NOTIFY pgrst, 'reload schema';

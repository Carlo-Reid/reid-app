-- Payroll: explaining why the pay slips do not add up to the source gross (George, Nov 14: "how do I explain or load the missing items,
-- and if it was a regular item I should be able to say that is a monthly amount to clear stuff off in one shot").
-- payroll_gross_notes: one reason for one source period (by its first day). payroll_gross_regular: an amount that is paid every
-- period (or every month) with no pay slip; the check takes it off each period it covers. Owners only. No names or amounts in this file.
CREATE TABLE IF NOT EXISTS public.payroll_gross_notes (
  period_from date PRIMARY KEY, note text NOT NULL, by_name text, at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.payroll_gross_regular (
  id bigserial PRIMARY KEY, amount numeric(12,2) NOT NULL, often text NOT NULL DEFAULT 'period' CHECK (often IN ('period', 'month')),
  reason text NOT NULL, from_date date, to_date date, by_name text, at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.payroll_gross_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_gross_regular ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_gross_notes, public.payroll_gross_regular FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.payroll_gross_info() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._src_owner() THEN jsonb_build_object(
    'notes', coalesce((SELECT jsonb_object_agg(period_from::text, jsonb_build_object('note', note, 'by', by_name, 'at', at)) FROM payroll_gross_notes), '{}'::jsonb),
    'regular', coalesce((SELECT jsonb_agg(jsonb_build_object('id', id, 'amount', amount, 'often', often, 'reason', reason, 'from', from_date, 'to', to_date, 'by', by_name) ORDER BY id) FROM payroll_gross_regular), '[]'::jsonb))
  ELSE NULL END $f$;

CREATE OR REPLACE FUNCTION public.payroll_gross_note_set(p_from date, p_note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  IF p_from IS NULL THEN RAISE EXCEPTION 'Which period?'; END IF;
  IF nullif(btrim(coalesce(p_note, '')), '') IS NULL THEN DELETE FROM payroll_gross_notes WHERE period_from = p_from;
  ELSE INSERT INTO payroll_gross_notes (period_from, note, by_name) VALUES (p_from, left(btrim(p_note), 500), public._staff_name(public.current_app_user_id()))
    ON CONFLICT (period_from) DO UPDATE SET note = EXCLUDED.note, by_name = EXCLUDED.by_name, at = now(); END IF;
END $f$;

CREATE OR REPLACE FUNCTION public.payroll_gross_regular_set(p jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint := nullif(p->>'id', '')::bigint;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  IF nullif(p->>'amount', '') IS NULL OR (p->>'amount')::numeric = 0 THEN RAISE EXCEPTION 'Type the amount'; END IF;
  IF nullif(btrim(coalesce(p->>'reason', '')), '') IS NULL THEN RAISE EXCEPTION 'Type what the amount is for'; END IF;
  IF v_id IS NULL THEN
    INSERT INTO payroll_gross_regular (amount, often, reason, from_date, to_date, by_name)
    VALUES ((p->>'amount')::numeric, coalesce(nullif(p->>'often', ''), 'period'), left(btrim(p->>'reason'), 300), nullif(p->>'from', '')::date, nullif(p->>'to', '')::date,
      public._staff_name(public.current_app_user_id())) RETURNING id INTO v_id;
  ELSE
    UPDATE payroll_gross_regular SET amount = (p->>'amount')::numeric, often = coalesce(nullif(p->>'often', ''), 'period'), reason = left(btrim(p->>'reason'), 300),
      from_date = nullif(p->>'from', '')::date, to_date = nullif(p->>'to', '')::date, by_name = public._staff_name(public.current_app_user_id()), at = now() WHERE id = v_id;
  END IF;
  RETURN v_id;
END $f$;

CREATE OR REPLACE FUNCTION public.payroll_gross_regular_del(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  DELETE FROM payroll_gross_regular WHERE id = p_id;
END $f$;

REVOKE EXECUTE ON FUNCTION public.payroll_gross_info(), public.payroll_gross_note_set(date, text), public.payroll_gross_regular_set(jsonb), public.payroll_gross_regular_del(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_gross_info(), public.payroll_gross_note_set(date, text), public.payroll_gross_regular_set(jsonb), public.payroll_gross_regular_del(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

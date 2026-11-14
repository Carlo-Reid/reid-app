-- T4 slips (George, Nov 14: "make it so I can upload the T4 also so we can have a record of their total for the year and it should match the pay
-- and everything should balance and if not we need to check why"). One T4 per person per year, read from the accountant's T4 PDF in the browser.
-- The boxes are kept; the SIN is never kept (the page picture has it covered before it is saved). Owners only.
-- Balance: box 14 (employment income) against the gross on the pay slips with a cheque date in that year, box 16 CPP, box 18 EI, box 22 tax.
CREATE TABLE IF NOT EXISTS public.payroll_t4 (
  id bigserial PRIMARY KEY, staff_id bigint NOT NULL REFERENCES public.payroll_staff(id) ON DELETE CASCADE, year int NOT NULL,
  b14 numeric(12,2), b16 numeric(12,2), b18 numeric(12,2), b20 numeric(12,2), b22 numeric(12,2), b24 numeric(12,2), b26 numeric(12,2),
  b44 numeric(12,2), b46 numeric(12,2), b52 numeric(12,2), other jsonb, slip_name text, page_path text, file_name text, note text,
  loaded_by text, loaded_at timestamptz NOT NULL DEFAULT now(), UNIQUE (staff_id, year));
ALTER TABLE public.payroll_t4 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_t4 FROM PUBLIC, anon, authenticated;

-- the payroll_staff row for a person: by id, by app user (made if missing), or by the name on the paper (made if new)
CREATE OR REPLACE FUNCTION public._payroll_staff_for(p_staff bigint, p_user bigint, p_name text, p_block text) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE sid bigint := p_staff; nm text := btrim(coalesce(p_name, ''));
BEGIN
  IF sid IS NULL AND p_user IS NOT NULL THEN
    SELECT id INTO sid FROM payroll_staff WHERE app_user_id = p_user;
    IF sid IS NULL THEN INSERT INTO payroll_staff (app_user_id, name) VALUES (p_user, nm) RETURNING id INTO sid; END IF;
  END IF;
  IF sid IS NULL AND nm <> '' THEN
    SELECT id INTO sid FROM payroll_staff WHERE app_user_id IS NULL AND (lower(name) = lower(nm) OR lower(nm) = ANY (SELECT lower(a) FROM unnest(aliases) a)) LIMIT 1;
    IF sid IS NULL THEN INSERT INTO payroll_staff (name, block) VALUES (nm, nullif(p_block, '')) RETURNING id INTO sid; END IF;
  END IF;
  RETURN sid;
END $f$;
REVOKE EXECUTE ON FUNCTION public._payroll_staff_for(bigint, bigint, text, text) FROM PUBLIC, anon, authenticated;

-- what the pay slips add up to for each person in a year (by cheque date), to check the T4s against
CREATE OR REPLACE FUNCTION public.payroll_t4_slipsums(p_year int) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._src_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('staff', ps.id, 'user', ps.app_user_id, 'n', x.n,
      'gross', x.g, 'cpp', x.c, 'ei', x.e, 'tax', x.t))
    FROM (SELECT staff_id, count(*) n, sum(gross) g, sum(cpp) c, sum(ei) e, sum(tax) t FROM payroll_slips
          WHERE cheque_date >= make_date(p_year, 1, 1) AND cheque_date < make_date(p_year + 1, 1, 1) GROUP BY staff_id) x
    JOIN payroll_staff ps ON ps.id = x.staff_id), '[]'::jsonb) ELSE '[]'::jsonb END $f$;

CREATE OR REPLACE FUNCTION public.payroll_t4_save(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE x jsonb; sid bigint; n int := 0; who text := public._staff_name(public.current_app_user_id()); nm text;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can load T4s'; END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p -> 't4s', '[]'::jsonb)) LOOP
    nm := btrim(x ->> 'name');
    IF nullif(x ->> 'year', '') IS NULL OR (x ->> 'year')::int NOT BETWEEN 2000 AND 2100 THEN RAISE EXCEPTION 'The T4 of % has no year', coalesce(nm, '?'); END IF;
    sid := public._payroll_staff_for(nullif(x ->> 'staff', '')::bigint, nullif(x ->> 'user', '')::bigint, nm, x ->> 'block');
    IF sid IS NULL THEN RAISE EXCEPTION 'Who is the T4 of %?', coalesce(nm, '?'); END IF;
    UPDATE payroll_staff SET aliases = CASE WHEN nm = '' OR lower(nm) = ANY (SELECT lower(a) FROM unnest(aliases) a) OR lower(name) = lower(nm) THEN aliases ELSE aliases || nm END WHERE id = sid;
    INSERT INTO payroll_t4 (staff_id, year, b14, b16, b18, b20, b22, b24, b26, b44, b46, b52, other, slip_name, page_path, file_name, loaded_by)
      VALUES (sid, (x ->> 'year')::int, (x ->> 'b14')::numeric, (x ->> 'b16')::numeric, (x ->> 'b18')::numeric, (x ->> 'b20')::numeric, (x ->> 'b22')::numeric,
        (x ->> 'b24')::numeric, (x ->> 'b26')::numeric, (x ->> 'b44')::numeric, (x ->> 'b46')::numeric, (x ->> 'b52')::numeric, x -> 'other', nullif(nm, ''),
        nullif(x ->> 'page', ''), p ->> 'file', who)
      ON CONFLICT (staff_id, year) DO UPDATE SET b14 = EXCLUDED.b14, b16 = EXCLUDED.b16, b18 = EXCLUDED.b18, b20 = EXCLUDED.b20, b22 = EXCLUDED.b22,
        b24 = EXCLUDED.b24, b26 = EXCLUDED.b26, b44 = EXCLUDED.b44, b46 = EXCLUDED.b46, b52 = EXCLUDED.b52, other = EXCLUDED.other, slip_name = EXCLUDED.slip_name,
        page_path = coalesce(EXCLUDED.page_path, payroll_t4.page_path), file_name = EXCLUDED.file_name, loaded_by = EXCLUDED.loaded_by, loaded_at = now();
    n := n + 1;
  END LOOP;
  RETURN jsonb_build_object('saved', n);
END $f$;

CREATE OR REPLACE FUNCTION public.payroll_t4_note(p_id bigint, p_note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  UPDATE payroll_t4 SET note = nullif(btrim(p_note), '') WHERE id = p_id;
END $f$;
CREATE OR REPLACE FUNCTION public.payroll_t4_del(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  DELETE FROM payroll_t4 WHERE id = p_id;
END $f$;

-- every T4 with what the pay slips add up to that year, and the people paid that year who have no T4 yet. p_staff: one person only.
CREATE OR REPLACE FUNCTION public.payroll_t4_list(p_staff bigint DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  WITH sums AS (SELECT staff_id, extract(year FROM cheque_date)::int AS y, count(*) n, sum(gross) g, sum(cpp) c, sum(ei) e, sum(tax) t
                FROM payroll_slips WHERE p_staff IS NULL OR staff_id = p_staff GROUP BY 1, 2),
  t4 AS (SELECT * FROM payroll_t4 WHERE p_staff IS NULL OR staff_id = p_staff),
  k AS (SELECT staff_id, y FROM sums UNION SELECT staff_id, year FROM t4)
  SELECT CASE WHEN public._src_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'staff', ps.id, 'user', ps.app_user_id,
      'name', coalesce(t.slip_name, (SELECT nullif(btrim(z.slip_name), '') FROM payroll_slips z WHERE z.staff_id = ps.id ORDER BY z.cheque_date DESC LIMIT 1), ps.name),
      'year', k.y, 'b14', t.b14, 'b16', t.b16, 'b18', t.b18, 'b20', t.b20, 'b22', t.b22, 'b24', t.b24, 'b26', t.b26, 'b44', t.b44, 'b46', t.b46, 'b52', t.b52,
      'page', t.page_path, 'note', t.note, 'file', t.file_name, 'at', t.loaded_at, 'by', t.loaded_by,
      'n', s.n, 'gross', s.g, 'cpp', s.c, 'ei', s.e, 'tax', s.t) ORDER BY k.y DESC, coalesce(t.slip_name, ps.name))
    FROM k JOIN payroll_staff ps ON ps.id = k.staff_id LEFT JOIN t4 t ON t.staff_id = k.staff_id AND t.year = k.y
    LEFT JOIN sums s ON s.staff_id = k.staff_id AND s.y = k.y), '[]'::jsonb) ELSE '[]'::jsonb END $f$;

REVOKE EXECUTE ON FUNCTION public.payroll_t4_slipsums(int), public.payroll_t4_save(jsonb), public.payroll_t4_note(bigint, text), public.payroll_t4_del(bigint), public.payroll_t4_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_t4_slipsums(int), public.payroll_t4_save(jsonb), public.payroll_t4_note(bigint, text), public.payroll_t4_del(bigint), public.payroll_t4_list(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

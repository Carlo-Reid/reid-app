-- Payroll overview for the private Payroll list (George, Nov 13): what each person was paid each year and each month (from the
-- pay slips loaded), and every cheque date on file with its count, gross and source (tax + CPP and EI, theirs and ours), so the page
-- can show year-to-date pay on the cards, totals by block and by month with the people paid, the pay days with no slips, and an
-- estimate of the source for a period before the accountant's email. Owners only. Our share: CPP the same as theirs, EI 1.4 times.
CREATE OR REPLACE FUNCTION public.payroll_overview() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._src_owner() THEN jsonb_build_object(
    'people', coalesce((SELECT jsonb_agg(jsonb_build_object('staff', ps.id, 'user', ps.app_user_id, 'y', t.y, 'slips', t.slips,
        'gross', t.gross, 'vac', t.vac, 'tax', t.tax, 'cpp', t.cpp, 'ei', t.ei, 'net', t.net, 'co', t.cpp + round(t.ei * 1.4, 2),
        'cost', t.gross + t.cpp + round(t.ei * 1.4, 2), 'last', t.last, 'vac_pct', ps.vac_pct,
        'full', (SELECT nullif(btrim(z.slip_name), '') FROM payroll_slips z WHERE z.staff_id = ps.id ORDER BY z.cheque_date DESC LIMIT 1)))
      FROM (SELECT s.staff_id, extract(year FROM s.cheque_date)::int AS y, count(*) AS slips, coalesce(sum(s.gross), 0) AS gross,
                   coalesce(sum(s.vac), 0) AS vac, coalesce(sum(s.tax), 0) AS tax, coalesce(sum(s.cpp), 0) AS cpp, coalesce(sum(s.ei), 0) AS ei,
                   coalesce(sum(s.net), 0) AS net, max(s.cheque_date) AS last
            FROM payroll_slips s GROUP BY 1, 2) t JOIN payroll_staff ps ON ps.id = t.staff_id), '[]'::jsonb),
    'months', coalesce((SELECT jsonb_agg(jsonb_build_object('staff', ps.id, 'user', ps.app_user_id, 'm', t.m, 'slips', t.slips,
        'gross', t.gross, 'vac', t.vac, 'tax', t.tax, 'cpp', t.cpp, 'ei', t.ei, 'net', t.net, 'cost', t.gross + t.cpp + round(t.ei * 1.4, 2)))
      FROM (SELECT s.staff_id, to_char(s.cheque_date, 'YYYY-MM') AS m, count(*) AS slips, coalesce(sum(s.gross), 0) AS gross,
                   coalesce(sum(s.vac), 0) AS vac, coalesce(sum(s.tax), 0) AS tax, coalesce(sum(s.cpp), 0) AS cpp, coalesce(sum(s.ei), 0) AS ei,
                   coalesce(sum(s.net), 0) AS net
            FROM payroll_slips s GROUP BY 1, 2) t JOIN payroll_staff ps ON ps.id = t.staff_id), '[]'::jsonb),
    'cheques', coalesce((SELECT jsonb_agg(jsonb_build_object('d', d, 'n', n, 'gross', g, 'src', src) ORDER BY d)
      FROM (SELECT s.cheque_date AS d, count(*) AS n, coalesce(sum(s.gross), 0) AS g,
                   coalesce(sum(coalesce(s.tax, 0) + 2 * coalesce(s.cpp, 0) + round(2.4 * coalesce(s.ei, 0), 2)), 0) AS src
            FROM payroll_slips s GROUP BY 1) c), '[]'::jsonb))
  ELSE '{}'::jsonb END $f$;
GRANT EXECUTE ON FUNCTION public.payroll_overview() TO authenticated;

-- every pay slip of one month (by cheque date), one line each, with the full name printed on the slip (George, Nov 13: "each cheque
-- individualized rather than them both added together"). Owners only.
CREATE OR REPLACE FUNCTION public.payroll_month_slips(p_m text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._src_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('staff', ps.id, 'user', ps.app_user_id, 'cheque', s.cheque_date, 'slip_no', s.slip_no,
      'name', coalesce(nullif(btrim(s.slip_name), ''), ps.name), 'gross', s.gross, 'vac', s.vac, 'vac_pct', s.vac_pct, 'tax', s.tax, 'cpp', s.cpp, 'ei', s.ei, 'net', s.net,
      'cost', coalesce(s.gross, 0) + coalesce(s.cpp, 0) + round(coalesce(s.ei, 0) * 1.4, 2), 'page', s.page_path) ORDER BY s.cheque_date, s.slip_no)
    FROM payroll_slips s JOIN payroll_staff ps ON ps.id = s.staff_id WHERE to_char(s.cheque_date, 'YYYY-MM') = p_m), '[]'::jsonb) ELSE '[]'::jsonb END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_month_slips(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_month_slips(text) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- someone who is usually paid but has no pay slip on a pay run (George, Nov 13: "let me know that maybe you did not see a cheque from
-- someone on the pay run… then I can check off that is correct no cheque this period, or upload one, or they are no longer with us").
-- A pay run = a cheque date with 3 or more slips. Usually paid = a slip on at least 2 of the 3 pay runs before it. A slip within 4 days
-- of the run counts. Not asked: after their last day, or once marked "no cheque this period" (payroll_no_slip).
CREATE TABLE IF NOT EXISTS public.payroll_no_slip (
  staff_id bigint NOT NULL REFERENCES public.payroll_staff(id) ON DELETE CASCADE, run_date date NOT NULL, by_name text, at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (staff_id, run_date));
ALTER TABLE public.payroll_no_slip ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_no_slip FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.payroll_missing_slips() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  WITH runs AS (SELECT cheque_date AS d FROM payroll_slips GROUP BY 1 HAVING count(*) >= 3),
  r AS (SELECT d, row_number() OVER (ORDER BY d) AS i FROM runs),
  cand AS (
    SELECT r.d, ps.id AS staff, ps.app_user_id AS u, ps.name, ps.left_on,
      (SELECT count(*) FROM r p WHERE p.i BETWEEN r.i - 3 AND r.i - 1
         AND EXISTS (SELECT 1 FROM payroll_slips s WHERE s.staff_id = ps.id AND s.cheque_date BETWEEN p.d - 4 AND p.d + 4)) AS seen
    FROM r CROSS JOIN payroll_staff ps WHERE r.i > 3)
  SELECT CASE WHEN public._src_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('d', c.d, 'staff', c.staff, 'user', c.u,
      'name', coalesce((SELECT nullif(btrim(z.slip_name), '') FROM payroll_slips z WHERE z.staff_id = c.staff ORDER BY z.cheque_date DESC LIMIT 1), c.name),
      'last', (SELECT max(z.cheque_date) FROM payroll_slips z WHERE z.staff_id = c.staff AND z.cheque_date < c.d)) ORDER BY c.d DESC, c.name)
    FROM cand c WHERE c.seen >= 2 AND (c.left_on IS NULL OR c.left_on > c.d)
      -- not asked inside a break of more than 3 months (George, Nov 13: no cheque in 3 months = no longer with us; a cheque after that is a return, asked in payroll_returns)
      AND (SELECT CASE WHEN nx IS NULL THEN public._src_today() - ls <= 92 ELSE nx - ls <= 92 END FROM (SELECT
            (SELECT max(z.cheque_date) FROM payroll_slips z WHERE z.staff_id = c.staff AND z.cheque_date < c.d) AS ls,
            (SELECT min(z.cheque_date) FROM payroll_slips z WHERE z.staff_id = c.staff AND z.cheque_date > c.d) AS nx) g)
      AND NOT EXISTS (SELECT 1 FROM payroll_slips s WHERE s.staff_id = c.staff AND s.cheque_date BETWEEN c.d - 4 AND c.d + 4)
      -- paid before and after the run: they are plainly still with us, so it is not asked; the pay history still says the run had no cheque
      -- (George, Nov 14: "he just missed the 1 pay run but was paid after and before… just hide from this section… check in their profile")
      AND NOT EXISTS (SELECT 1 FROM payroll_slips s WHERE s.staff_id = c.staff AND s.cheque_date > c.d + 4)
      AND NOT EXISTS (SELECT 1 FROM payroll_no_slip n WHERE n.staff_id = c.staff AND n.run_date = c.d)), '[]'::jsonb) ELSE '[]'::jsonb END $f$;
CREATE OR REPLACE FUNCTION public.payroll_no_slip_set(p_staff bigint, p_d date, p_on boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  IF p_on THEN INSERT INTO payroll_no_slip (staff_id, run_date, by_name) VALUES (p_staff, p_d, public._staff_name(public.current_app_user_id())) ON CONFLICT DO NOTHING;
  ELSE DELETE FROM payroll_no_slip WHERE staff_id = p_staff AND run_date = p_d; END IF;
  PERFORM public._payroll_staff_refresh(p_staff);   -- the pay history line ("No cheque for this person… Checked: that is right.") is written by the refresh
END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_missing_slips(), public.payroll_no_slip_set(bigint, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_missing_slips(), public.payroll_no_slip_set(bigint, date, boolean) TO authenticated;
-- a cheque after a break of more than 3 months (George, Nov 13): 3 months to a year → ask: rehired, back from a long holiday, or another reason;
-- over a year → a new hire who came back, written by itself. payroll_return keeps the answer (and the pay history shows it).
CREATE TABLE IF NOT EXISTS public.payroll_return (
  staff_id bigint NOT NULL REFERENCES public.payroll_staff(id) ON DELETE CASCADE, back_on date NOT NULL, reason text NOT NULL, note text, by_name text, at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (staff_id, back_on));
ALTER TABLE public.payroll_return ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_return FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public._payroll_gaps(p_staff bigint) RETURNS TABLE (left_after date, back_on date, days int) LANGUAGE sql STABLE AS $f$
  SELECT ls, d, (d - ls)::int FROM (SELECT d, lag(d) OVER (ORDER BY d) AS ls FROM (SELECT DISTINCT cheque_date AS d FROM payroll_slips WHERE staff_id = p_staff) x) y
  WHERE ls IS NOT NULL AND d - ls > 92 $f$;
CREATE OR REPLACE FUNCTION public.payroll_returns() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._src_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('staff', ps.id, 'user', ps.app_user_id,
      'name', coalesce((SELECT nullif(btrim(z.slip_name), '') FROM payroll_slips z WHERE z.staff_id = ps.id ORDER BY z.cheque_date DESC LIMIT 1), ps.name),
      'left_after', g.left_after, 'back_on', g.back_on, 'days', g.days) ORDER BY g.back_on DESC, ps.name)
    FROM payroll_staff ps CROSS JOIN LATERAL public._payroll_gaps(ps.id) g
    WHERE g.days <= 365 AND NOT EXISTS (SELECT 1 FROM payroll_return r WHERE r.staff_id = ps.id AND r.back_on = g.back_on)), '[]'::jsonb) ELSE '[]'::jsonb END $f$;
CREATE OR REPLACE FUNCTION public.payroll_return_set(p_staff bigint, p_back date, p_reason text, p_note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  IF p_reason NOT IN ('rehired', 'holiday', 'other') THEN RAISE EXCEPTION 'Pick rehired, a long holiday or another reason'; END IF;
  INSERT INTO payroll_return (staff_id, back_on, reason, note, by_name) VALUES (p_staff, p_back, p_reason, nullif(btrim(p_note), ''), public._staff_name(public.current_app_user_id()))
    ON CONFLICT (staff_id, back_on) DO UPDATE SET reason = EXCLUDED.reason, note = EXCLUDED.note, by_name = EXCLUDED.by_name, at = now();
  PERFORM public._payroll_staff_refresh(p_staff);
END $f$;
REVOKE EXECUTE ON FUNCTION public._payroll_gaps(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_returns(), public.payroll_return_set(bigint, date, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_returns(), public.payroll_return_set(bigint, date, text, text) TO authenticated;
DELETE FROM public.payroll_staff_log WHERE NOT auto AND note LIKE 'No cheque on the pay run of % (checked: that is right).';   -- now written by the refresh, with the pay period
-- the pay history gets the breaks: written again for everyone on each update
DO $do$ DECLARE r record; BEGIN FOR r IN SELECT DISTINCT staff_id FROM public.payroll_slips LOOP PERFORM public._payroll_staff_refresh(r.staff_id); END LOOP; END $do$;
NOTIFY pgrst, 'reload schema';


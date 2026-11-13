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

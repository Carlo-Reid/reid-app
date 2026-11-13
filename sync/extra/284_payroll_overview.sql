-- Payroll overview for the private Payroll list (George, Nov 13): what each person was paid each year and each month (from the
-- pay slips loaded), and every cheque date on file with its count, gross and source (tax + CPP and EI, theirs and ours), so the page
-- can show year-to-date pay on the cards, totals by block and by month with the people paid, the pay days with no slips, and an
-- estimate of the source for a period before the accountant's email. Owners only. Our share: CPP the same as theirs, EI 1.4 times.
CREATE OR REPLACE FUNCTION public.payroll_overview() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._src_owner() THEN jsonb_build_object(
    'people', coalesce((SELECT jsonb_agg(jsonb_build_object('staff', ps.id, 'user', ps.app_user_id, 'y', t.y, 'slips', t.slips,
        'gross', t.gross, 'vac', t.vac, 'tax', t.tax, 'cpp', t.cpp, 'ei', t.ei, 'net', t.net, 'co', t.cpp + round(t.ei * 1.4, 2),
        'cost', t.gross + t.cpp + round(t.ei * 1.4, 2), 'last', t.last, 'vac_pct', ps.vac_pct))
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

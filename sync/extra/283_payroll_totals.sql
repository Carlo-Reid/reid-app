-- Payroll totals by month, from the pay slips loaded (George, Nov 13: "show me the totals for payroll like it does for the source").
-- Owners only. A slip counts in the month of its cheque date. Our share: CPP the same as the employee's, EI 1.4 times.
CREATE OR REPLACE FUNCTION public.payroll_totals() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._src_owner() THEN coalesce((
    SELECT jsonb_agg(jsonb_build_object('m', m, 'pays', pays, 'people', people, 'slips', slips, 'gross', gross, 'vac', vac, 'commission', com,
      'tax', tax, 'cpp', cpp, 'ei', ei, 'net', net, 'co', cpp + round(ei * 1.4, 2), 'cost', gross + cpp + round(ei * 1.4, 2),
      'hourly', hourly, 'ot', ot, 'com2', com2, 'oncall', oncall, 'stat', stat, 'other', other, 'ben', ben) ORDER BY m)
    FROM (SELECT to_char(s.cheque_date, 'YYYY-MM') AS m, count(DISTINCT s.cheque_date) AS pays, count(DISTINCT s.staff_id) AS people, count(*) AS slips,
                 coalesce(sum(s.gross), 0) AS gross, coalesce(sum(s.vac), 0) AS vac, coalesce(sum(s.commission), 0) AS com,
                 coalesce(sum(s.tax), 0) AS tax, coalesce(sum(s.cpp), 0) AS cpp, coalesce(sum(s.ei), 0) AS ei, coalesce(sum(s.net), 0) AS net,
                 coalesce(sum((pp ->> 'hourly')::numeric), 0) AS hourly, coalesce(sum((pp ->> 'ot')::numeric), 0) AS ot, coalesce(sum((pp ->> 'com')::numeric), 0) AS com2,
                   coalesce(sum((pp ->> 'oncall')::numeric), 0) AS oncall, coalesce(sum((pp ->> 'stat')::numeric), 0) AS stat, coalesce(sum((pp ->> 'other')::numeric), 0) AS other,
                   coalesce(sum((pp ->> 'ben')::numeric), 0) AS ben
          FROM payroll_slips s CROSS JOIN LATERAL public._slip_parts(s.earn, s.adj, s.dfg) pp GROUP BY 1) t), '[]'::jsonb) ELSE '[]'::jsonb END $f$;
GRANT EXECUTE ON FUNCTION public.payroll_totals() TO authenticated;

-- Commissions page: the list of staff a new sales person can be picked from (anyone active), and merged duplicates left out.
-- Safe to run more than once.
CREATE OR REPLACE FUNCTION public.comm_setup_get()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT CASE WHEN NOT public._can_installs() THEN NULL ELSE jsonb_build_object(
    'groups', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'keywords', keywords) ORDER BY sort_order, name), '[]') FROM commission_groups),
    'people', (SELECT coalesce(jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', public._emp_name(e.id), 'pct', r.pct,
                 'groups', (SELECT coalesce(jsonb_object_agg(g.group_id, g.pct), '{}') FROM commission_group_rates g WHERE g.employee_id = e.id)) ORDER BY public._emp_name(e.id)), '[]')
               FROM employees e LEFT JOIN commission_rates r ON r.employee_id = e.id
               WHERE e.merged_into IS NULL AND (r.pct IS NOT NULL OR EXISTS (SELECT 1 FROM commission_group_rates g WHERE g.employee_id = e.id)
                  OR e.id IN (SELECT it.salesperson_id FROM install_tracking it WHERE it.salesperson_id IS NOT NULL)
                  OR e.id IN (SELECT j.sold_by_employee_id FROM jobs j WHERE j.sold_by_employee_id IS NOT NULL AND j.created_at > now() - interval '18 months'))),
    'staff', (SELECT coalesce(jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', public._emp_name(e.id), 'title', e.job_title) ORDER BY public._emp_name(e.id)), '[]')
              FROM employees e WHERE e.active AND e.merged_into IS NULL AND public._emp_name(e.id) IS NOT NULL AND e.first_name NOT LIKE 'ZPast-%')) END
$f$;
NOTIFY pgrst, 'reload schema';

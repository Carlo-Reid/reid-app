-- Payroll: the sales calls are split in two: Security Quote (security jobs) and Walk Site (all the others: HVAC quotes, site walks).
CREATE OR REPLACE FUNCTION public.payroll_tech_period(p_user bigint, p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_emp bigint; v_ids bigint[]; v_name text;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' AND p_user IS DISTINCT FROM public.current_app_user_id() THEN RETURN NULL; END IF;   -- a tech sees only their own
  SELECT a.employee_id, coalesce(nullif(concat_ws(' ', e.first_name, e.last_name), ''), a.login_email)
    INTO v_emp, v_name FROM app_users a LEFT JOIN employees e ON e.id = a.employee_id WHERE a.id = p_user;
  IF v_emp IS NULL THEN RETURN jsonb_build_object('name', v_name, 'calls', '[]'::jsonb, 'no_employee', true); END IF;
  v_ids := public._payroll_emp_ids(v_emp);
  RETURN jsonb_build_object('name', v_name, 'employee', v_emp, 'ids', to_jsonb(v_ids), 'calls', coalesce((
    SELECT jsonb_agg(jsonb_build_object(
        'id', t.id, 'job', t.job_id, 'visit', t.visit_id, 'source', t.source,
        'day', (coalesce(t.arrived_on, t.dispatched_on, t.done_on) AT TIME ZONE 'America/Toronto')::date,
        'on_way', t.dispatched_on, 'arrived', t.arrived_on, 'done', t.done_on, 'canceled', t.canceled_on,
        'job_number', j.job_number, 'job_type', jt.name, 'job_class', jt.job_class,
        'kind', CASE WHEN jt.job_class = 'install' OR jt.name ILIKE '%install%' THEN 'Install'
                     WHEN jt.name ~* 'maint|tune|clean|inspect|annual|check.?up|pm\M' THEN 'Maintenance'
                     WHEN jt.job_class = 'sales' OR jt.name ~* 'estimate|quote|sales' THEN
                       CASE WHEN jt.job_class = 'security' OR jt.name ~* 'security' THEN 'Security Quote' ELSE 'Walk Site' END
                     WHEN jt.name ~* 'warrant|recall|callback|call back' THEN 'Warranty'
                     ELSE 'Service' END,
        'customer', c.display_name, 'customer_id', coalesce(j.customer_id, l.customer_id),
        'address', concat_ws(', ', nullif(l.street, ''), nullif(l.city, '')))
      ORDER BY coalesce(t.dispatched_on, t.arrived_on, t.done_on), t.id)
    FROM job_timesheets t
    LEFT JOIN jobs j ON j.id = t.job_id
    LEFT JOIN job_types jt ON jt.id = j.job_type_id
    LEFT JOIN locations l ON l.id = j.location_id
    LEFT JOIN customers c ON c.id = coalesce(j.customer_id, l.customer_id)
    WHERE t.technician_id = ANY (v_ids) AND coalesce(t.active, true)
      AND (coalesce(t.arrived_on, t.dispatched_on, t.done_on) AT TIME ZONE 'America/Toronto')::date BETWEEN p_from AND p_to), '[]'::jsonb));
END $function$;
NOTIFY pgrst, 'reload schema';

-- Payroll (owners only). The people on it are the people on the Staff page: every log-in that isn't removed,
-- with the employee it's linked to. Add someone on Staff and they show up here; remove them and they go.
-- payroll_tech_period: one tech's calls for a pay period, day by day, from their timesheets
-- (ServiceTitan's and our own app's): on the way, arrived, done, the job type and the customer.

CREATE OR REPLACE FUNCTION public.payroll_people() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object(
      'user', a.id, 'employee', a.employee_id, 'email', a.login_email, 'role', a.role, 'active', a.active,
      'name', coalesce(nullif(concat_ws(' ', e.first_name, e.last_name), ''), a.login_email),
      'title', e.job_title, 'tech', coalesce(e.is_technician, false), 'wage', e.hourly_wage)
      ORDER BY a.active DESC, lower(coalesce(nullif(concat_ws(' ', e.first_name, e.last_name), ''), a.login_email)))
    FROM app_users a LEFT JOIN employees e ON e.id = a.employee_id
    WHERE a.deleted_at IS NULL), '[]'::jsonb);
END $function$;

-- the tech records that count as this person: the one their log-in is linked to, plus any merged into it (or it into)
CREATE OR REPLACE FUNCTION public._payroll_emp_ids(p_emp bigint) RETURNS bigint[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT array_agg(DISTINCT x) FROM (
    SELECT p_emp AS x
    UNION SELECT e.id FROM employees e WHERE e.merged_into = p_emp
    UNION SELECT e.merged_into FROM employees e WHERE e.id = p_emp AND e.merged_into IS NOT NULL
    UNION SELECT e2.id FROM employees e JOIN employees e2 ON e2.merged_into = e.merged_into WHERE e.id = p_emp AND e.merged_into IS NOT NULL) s
  WHERE x IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION public.payroll_tech_period(p_user bigint, p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_emp bigint; v_ids bigint[]; v_name text;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RETURN NULL; END IF;
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
                     WHEN jt.job_class = 'sales' OR jt.name ~* 'estimate|quote|sales' THEN 'Sales'
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

REVOKE EXECUTE ON FUNCTION public.payroll_people(), public._payroll_emp_ids(bigint), public.payroll_tech_period(bigint, date, date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public._payroll_emp_ids(bigint) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.payroll_people(), public.payroll_tech_period(bigint, date, date) TO authenticated;
NOTIFY pgrst, 'reload schema';

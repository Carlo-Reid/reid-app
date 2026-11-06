-- Payroll list: office staff (app role office, admin, accounting, dispatcher, warehouse) are not techs, even when ServiceTitan has them as a technician (e.g. Kevin, the service manager).
CREATE OR REPLACE FUNCTION public.payroll_people() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object(
      'user', a.id, 'employee', a.employee_id, 'email', a.login_email, 'role', a.role, 'active', a.active,
      'name', coalesce(nullif(concat_ws(' ', e.first_name, e.last_name), ''), a.login_email),
      'title', CASE WHEN a.role IN ('office', 'admin', 'accounting', 'dispatcher', 'warehouse') AND e.job_title ~* '^\s*technician\s*$' THEN 'Office staff' ELSE e.job_title END,
      'tech', coalesce(e.is_technician, false) AND a.role NOT IN ('office', 'admin', 'accounting', 'dispatcher', 'warehouse', 'owner'), 'wage', e.hourly_wage)
      ORDER BY a.active DESC, lower(coalesce(nullif(concat_ws(' ', e.first_name, e.last_name), ''), a.login_email)))
    FROM app_users a LEFT JOIN employees e ON e.id = a.employee_id
    WHERE a.deleted_at IS NULL), '[]'::jsonb);
END $function$;
NOTIFY pgrst, 'reload schema';

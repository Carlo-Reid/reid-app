-- The dispatch board by week or month: every call in a date range, short (each tech's days at a glance)
CREATE INDEX IF NOT EXISTS visits_scheduled_date ON public.visits (scheduled_date);
CREATE OR REPLACE FUNCTION public.dispatch_range(p_from date, p_to date)
 RETURNS TABLE(visit_id bigint, d date, arrival_start timestamptz, arrival_end timestamptz, duration integer, status text, job_id bigint, job_number text, job_type text, job_class text,
               customer_id bigint, customer_name text, city text, techs jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  SELECT v.id, v.scheduled_date, v.arrival_start, v.arrival_end, v.est_duration_minutes, v.status, j.id, j.job_number, t.name, t.job_class,
         c.id, c.display_name, l.city,
         (SELECT coalesce(jsonb_agg(jsonb_build_object('id', va.employee_id, 'name', public._emp_name(va.employee_id)) ORDER BY (va.role <> 'lead'), va.id), '[]') FROM visit_assignments va WHERE va.visit_id = v.id)
  FROM visits v
  JOIN jobs j ON j.id = v.job_id
  JOIN job_types t ON t.id = j.job_type_id
  JOIN customers c ON c.id = j.customer_id
  LEFT JOIN locations l ON l.id = j.location_id
  WHERE public.current_staff_role() IS NOT NULL AND p_to - p_from <= 62
    AND v.scheduled_date BETWEEN p_from AND p_to AND v.status <> 'cancelled'
  ORDER BY v.scheduled_date, v.arrival_start NULLS LAST, v.id
  LIMIT 5000
$function$;
REVOKE EXECUTE ON FUNCTION public.dispatch_range(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dispatch_range(date, date) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Dispatch board: a walk booked after a sale (a visit on the install job whose purpose starts "Walk the site")
-- shows the walk as its summary, so the board can mark it as a walk. Same as 99t_check_in.sql otherwise. Safe to run more than once.
CREATE OR REPLACE FUNCTION public.dispatch_day(p_date date)
 RETURNS TABLE(visit_id bigint, scheduled_date date, arrival_start timestamp with time zone, arrival_end timestamp with time zone, duration integer, status text, visit_number integer, job_id bigint, job_number text, job_type text, job_class text, summary text, priority text, business_unit text, customer_id bigint, customer_name text, street text, city text, postal_code text, techs jsonb, created_at timestamp with time zone, location_id bigint, lat numeric, lng numeric, province text, hood_id bigint, hood text, border_zone text, community_id bigint, community text, arrived_at timestamp with time zone, en_route_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET jit TO 'off'
AS $function$
  SELECT v.id, v.scheduled_date, v.arrival_start, v.arrival_end, v.est_duration_minutes, v.status, v.visit_number,
         j.id, j.job_number, t.name, t.job_class, CASE WHEN v.visit_purpose ~* '^\s*walk the site' THEN v.visit_purpose ELSE j.summary END, j.priority, b.name,
         c.id, c.display_name, l.street, l.city, l.postal_code,
         (SELECT coalesce(jsonb_agg(jsonb_build_object('id', va.employee_id, 'name', public._emp_name(va.employee_id), 'role', va.role)
                                    ORDER BY (va.role <> 'lead'), va.id), '[]') FROM visit_assignments va WHERE va.visit_id = v.id),
         v.created_at, l.id, l.latitude, l.longitude, l.province, h.id, h.name, l.border_zone, cm.id, cm.name, v.arrived_at, v.en_route_at
  FROM visits v
  JOIN jobs j ON j.id = v.job_id
  JOIN job_types t ON t.id = j.job_type_id
  LEFT JOIN business_units b ON b.id = j.business_unit_id
  JOIN customers c ON c.id = j.customer_id
  JOIN locations l ON l.id = j.location_id
  LEFT JOIN neighbourhoods h ON h.id = l.neighbourhood_id
  LEFT JOIN communities cm ON cm.id = l.community_id
  WHERE public.current_staff_role() IS NOT NULL
    AND ((p_date IS NOT NULL AND v.scheduled_date = p_date)
         OR (p_date IS NULL AND v.status = 'unscheduled' AND v.created_at > now() - interval '1 year'))
  ORDER BY v.arrival_start NULLS LAST, v.id
  LIMIT 1000
$function$;
REVOKE EXECUTE ON FUNCTION public.dispatch_day(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dispatch_day(date) TO authenticated;
NOTIFY pgrst, 'reload schema';

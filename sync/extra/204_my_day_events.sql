-- Tech Calls: the events on a tech's schedule that day (not calls), e.g. "Tire N Rim City", "George needs you". Staff only.
CREATE OR REPLACE FUNCTION public.my_day_events(p_date date, p_employee_id bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS NULL OR p_employee_id IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', n.id, 'start', n.starts_at, 'minutes', n.duration_min, 'name', n.name, 'summary', n.summary, 'all_day', n.all_day) ORDER BY n.starts_at)
    FROM public.st_nonjob_appts n WHERE n.technician_id = ANY (public._payroll_emp_ids(p_employee_id)) AND COALESCE(n.active, true)
      AND (n.starts_at AT TIME ZONE 'America/Toronto')::date = p_date AND n.name !~* 'CALLS?\s+PAST\s+THIS'), '[]'::jsonb);
END $function$;
REVOKE EXECUTE ON FUNCTION public.my_day_events(date, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_day_events(date, bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

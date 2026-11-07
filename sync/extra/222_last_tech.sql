-- Book a call → Another visit: the last tech who was at this job (or, with no job picked, at this address), for the "Last tech there" box.
-- Safe to run more than once.
CREATE OR REPLACE FUNCTION public.last_tech_there(p_job bigint, p_location bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE (
    SELECT jsonb_build_object('id', va.employee_id, 'name', public._emp_name(va.employee_id), 'date', v.scheduled_date, 'job_number', j.job_number, 'same_job', j.id = p_job)
    FROM visits v JOIN jobs j ON j.id = v.job_id JOIN visit_assignments va ON va.visit_id = v.id
    WHERE (j.id = p_job OR (j.location_id = p_location AND p_location IS NOT NULL))
      AND v.scheduled_date IS NOT NULL AND v.scheduled_date <= (now() AT TIME ZONE 'America/Toronto')::date AND v.status <> 'cancelled'
    ORDER BY (j.id = p_job) DESC, v.scheduled_date DESC, (va.role = 'lead') DESC, va.id
    LIMIT 1) END $f$;
REVOKE EXECUTE ON FUNCTION public.last_tech_there(bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.last_tech_there(bigint, bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Book a call → Reid → Service → Call Back: pick the earlier call it's for; the new job is attached to it (jobs.original_job_id).
-- Safe to run more than once.
CREATE OR REPLACE FUNCTION public.callback_jobs(p_customer bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(x ORDER BY x ->> 'last' DESC NULLS LAST) FROM (
    SELECT jsonb_build_object('id', j.id, 'job_number', j.job_number, 'job_type', jt.name, 'summary', j.summary, 'status', j.status, 'location_id', j.location_id,
      'last', (SELECT max(v.scheduled_date) FROM visits v WHERE v.job_id = j.id AND v.status <> 'cancelled' AND v.scheduled_date <= current_date),
      'tech', (SELECT public._emp_name(va.employee_id) FROM visits v JOIN visit_assignments va ON va.visit_id = v.id
               WHERE v.job_id = j.id AND v.status <> 'cancelled' AND v.scheduled_date <= current_date ORDER BY v.scheduled_date DESC, (va.role = 'lead') DESC LIMIT 1)) AS x
    FROM jobs j LEFT JOIN job_types jt ON jt.id = j.job_type_id
    WHERE j.customer_id = p_customer AND j.status <> 'cancelled' AND j.created_at > now() - interval '3 years'
      AND EXISTS (SELECT 1 FROM visits v WHERE v.job_id = j.id AND v.status <> 'cancelled' AND v.scheduled_date <= current_date)
    ORDER BY j.created_at DESC LIMIT 40) q), '[]'::jsonb) END $f$;
CREATE OR REPLACE FUNCTION public.set_job_original(p_job bigint, p_original bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Not signed in'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jobs a JOIN jobs b ON b.customer_id = a.customer_id WHERE a.id = p_job AND b.id = p_original) THEN RAISE EXCEPTION 'That job is for a different customer'; END IF;
  UPDATE jobs SET original_job_id = p_original WHERE id = p_job;
END $function$;
REVOKE EXECUTE ON FUNCTION public.callback_jobs(bigint), public.set_job_original(bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.callback_jobs(bigint), public.set_job_original(bigint, bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

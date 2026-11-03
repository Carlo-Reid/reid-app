-- Find any number: for a job found (a sales call, duct cleaning, service call…), the install job it's attached to,
-- like the Sales page shows. First the install made from a proposal on that job; else the customer's install job
-- closest in time (within 6 months), marked as matched by customer. Safe to run more than once.
CREATE OR REPLACE FUNCTION public.job_install_links(p_jobs bigint[])
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('job_id', j.id, 'inst_id', ij.id, 'inst_number', ij.job_number, 'inst_status', ij.status,
             'inst_type', (SELECT name FROM job_types WHERE id = ij.job_type_id), 'guessed', ij.guessed,
             'visit_date', (SELECT v.scheduled_date FROM visits v WHERE v.job_id = ij.id ORDER BY v.visit_number DESC LIMIT 1),
             'done_on', (ij.completed_at AT TIME ZONE 'America/Toronto')::date))
    FROM jobs j JOIN job_types jt ON jt.id = j.job_type_id
    CROSS JOIN LATERAL (
      SELECT x.*, false AS guessed FROM jobs x JOIN job_types xt ON xt.id = x.job_type_id AND xt.job_class = 'install'
       WHERE x.id <> j.id AND (x.sold_estimate_id IN (SELECT e.id FROM estimates e WHERE e.job_id = j.id)
                               OR x.from_estimate_id IN (SELECT e.id FROM estimates e WHERE e.job_id = j.id))
      UNION ALL
      SELECT * FROM (SELECT x.*, true AS guessed FROM jobs x JOIN job_types xt ON xt.id = x.job_type_id AND xt.job_class = 'install'
       WHERE x.id <> j.id AND x.customer_id = j.customer_id AND x.status <> 'cancelled'
         AND x.created_at BETWEEN j.created_at - interval '6 months' AND j.created_at + interval '6 months'
         AND NOT EXISTS (SELECT 1 FROM jobs y JOIN estimates e ON e.job_id = j.id WHERE y.sold_estimate_id = e.id OR y.from_estimate_id = e.id)
       ORDER BY abs(extract(epoch FROM x.created_at - j.created_at)) LIMIT 1) g
    ) ij
    WHERE j.id = ANY (p_jobs[1:20]) AND jt.job_class <> 'install'), '[]'::jsonb) END
$function$;
REVOKE EXECUTE ON FUNCTION public.job_install_links(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.job_install_links(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

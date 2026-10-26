-- 99zzzV: keep the sold-on-a-call list ready-made so commission loads fast. Also runs every night from sync/extra/036.
-- =====================================================================
-- Keep the list of "sold on a call" sales ready-made (working it out every time made the install list slow):
-- the nightly sync rebuilds it, and opening the Sales page refreshes it when it's over 10 minutes old.
-- Runs every night after 035. Safe to run more than once.
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.comm_sale_jobs_cache (job_id bigint PRIMARY KEY, est_id bigint, sale_job_id bigint);
CREATE INDEX IF NOT EXISTS comm_sale_jobs_cache_sale_idx ON public.comm_sale_jobs_cache (sale_job_id);
ALTER TABLE public.comm_sale_jobs_cache ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.comm_sale_jobs_cache FROM anon, authenticated;
CREATE TABLE IF NOT EXISTS public.comm_sale_jobs_meta (id int PRIMARY KEY DEFAULT 1 CHECK (id = 1), refreshed_at timestamptz);
INSERT INTO public.comm_sale_jobs_meta (id) VALUES (1) ON CONFLICT DO NOTHING;
ALTER TABLE public.comm_sale_jobs_meta ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.comm_sale_jobs_meta FROM anon, authenticated;

-- working it out (what _comm_sale_jobs used to do every time)
CREATE OR REPLACE FUNCTION public._comm_sale_jobs_calc()
RETURNS TABLE (job_id bigint, est_id bigint, sale_job_id bigint) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public SET jit = off AS $f$
  WITH earners AS (SELECT employee_id FROM commission_rates UNION SELECT employee_id FROM commission_group_rates),
  sold AS (
    SELECT e.id, e.job_id, e.accepted_option_id FROM estimates e JOIN jobs j ON j.id = e.job_id JOIN job_types t ON t.id = j.job_type_id
    WHERE e.status = 'accepted' AND e.cancelled_at IS NULL AND e.created_at > now() - interval '3 years'
      AND t.job_class NOT IN ('install', 'sales') AND j.status <> 'cancelled'
      AND e.sold_by_employee_id IN (SELECT employee_id FROM earners)
      AND NOT EXISTS (SELECT 1 FROM jobs ij JOIN job_types it ON it.id = ij.job_type_id
                      WHERE ij.id <> e.job_id AND it.job_class = 'install' AND (ij.sold_estimate_id = e.id OR ij.from_estimate_id = e.id))),
  items AS (SELECT DISTINCT x.item_id FROM sold s JOIN estimate_lines x ON x.estimate_option_id = s.accepted_option_id WHERE x.item_id IS NOT NULL),
  counts AS (SELECT i.item_id FROM items i JOIN commission_groups g ON g.id = public._comm_group(i.item_id) WHERE g.name <> 'Other')
  SELECT DISTINCT ON (w.work_job) w.work_job, s.id, s.job_id FROM sold s
  CROSS JOIN LATERAL (SELECT coalesce((SELECT lj.id FROM jobs lj JOIN job_types lt ON lt.id = lj.job_type_id
                                       WHERE lj.id <> s.job_id AND lt.job_class <> 'sales' AND lj.status <> 'cancelled'
                                         AND (lj.sold_estimate_id = s.id OR lj.from_estimate_id = s.id)
                                       ORDER BY lj.created_at DESC LIMIT 1), s.job_id) AS work_job) w
  WHERE EXISTS (SELECT 1 FROM estimate_lines x JOIN counts c ON c.item_id = x.item_id WHERE x.estimate_option_id = s.accepted_option_id)
  ORDER BY w.work_job, s.id DESC
$f$;
REVOKE EXECUTE ON FUNCTION public._comm_sale_jobs_calc() FROM PUBLIC, anon, authenticated;

-- rebuild the ready-made list (skipped if it was rebuilt in the last 10 minutes, unless forced)
CREATE OR REPLACE FUNCTION public.refresh_comm_sale_jobs(p_force boolean DEFAULT false)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n int;
BEGIN
  IF NOT p_force AND public.current_staff_role() IS NULL THEN RETURN 0; END IF;
  IF NOT p_force AND EXISTS (SELECT 1 FROM comm_sale_jobs_meta WHERE refreshed_at > now() - interval '10 minutes') THEN RETURN -1; END IF;
  UPDATE comm_sale_jobs_meta SET refreshed_at = now() WHERE id = 1;
  DELETE FROM comm_sale_jobs_cache WHERE true;
  INSERT INTO comm_sale_jobs_cache (job_id, est_id, sale_job_id) SELECT job_id, est_id, sale_job_id FROM public._comm_sale_jobs_calc() ON CONFLICT (job_id) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION public.refresh_comm_sale_jobs(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refresh_comm_sale_jobs(boolean) TO authenticated;

-- everything that asks for the list now reads the ready-made one
CREATE OR REPLACE FUNCTION public._comm_sale_jobs()
RETURNS TABLE (job_id bigint, est_id bigint, sale_job_id bigint) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT job_id, est_id, sale_job_id FROM comm_sale_jobs_cache
$f$;
REVOKE EXECUTE ON FUNCTION public._comm_sale_jobs() FROM PUBLIC, anon, authenticated;

SELECT public.refresh_comm_sale_jobs(true) AS sales_on_calls;
NOTIFY pgrst, 'reload schema';

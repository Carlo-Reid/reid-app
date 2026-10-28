-- ServiceTitan job timesheets: each tech's dispatched / arrived / done times on a job (filled by the sync).
-- Job costing uses them for the real labour: each tech's own time on the job, at their own rate.
CREATE TABLE IF NOT EXISTS public.job_timesheets (
  id bigint PRIMARY KEY,           -- ServiceTitan's id
  job_id bigint,
  visit_id bigint,                 -- ServiceTitan appointment
  technician_id bigint,            -- employees.id
  dispatched_on timestamptz,
  arrived_on timestamptz,
  done_on timestamptz,
  canceled_on timestamptz,
  active boolean NOT NULL DEFAULT true,
  modified_on timestamptz,
  raw jsonb,
  synced_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS job_timesheets_job ON public.job_timesheets (job_id);
ALTER TABLE public.job_timesheets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.job_timesheets FROM PUBLIC, anon, authenticated;

-- job costing: each tech's timesheet (arrived to done) when the job has timesheets; otherwise each call's arrived/done times as before
SELECT public._patch_fn('inv_costing', $o$  vis AS (
    SELECT v.id, v.arrived_at, v.completed_at, extract(epoch FROM (v.completed_at - v.arrived_at)) / 3600.0 AS h
    FROM visits v JOIN j ON v.job_id = j.id
    WHERE v.arrived_at IS NOT NULL AND v.completed_at IS NOT NULL AND v.completed_at > v.arrived_at),
  vt AS (
    SELECT vis.id, vis.h, concat_ws(' ', e.first_name, e.last_name) AS nm,
           nullif(coalesce(nullif(e.labour_cost_per_hour, 0), e.hourly_wage * (1 + coalesce(e.burden_pct, 0) / 100)), 0) AS rate
    FROM vis JOIN visit_assignments va ON va.visit_id = vis.id JOIN employees e ON e.id = va.employee_id),$o$,
$n$  ts AS (   -- ServiceTitan timesheets: each tech's own arrived and done
    SELECT t.id, t.technician_id, t.arrived_on, t.done_on, extract(epoch FROM (t.done_on - t.arrived_on)) / 3600.0 AS h
    FROM job_timesheets t JOIN j ON t.job_id = j.id
    WHERE t.active AND t.canceled_on IS NULL AND t.arrived_on IS NOT NULL AND t.done_on IS NOT NULL AND t.done_on > t.arrived_on),
  vis AS (
    SELECT ts.id, ts.arrived_on AS arrived_at, ts.done_on AS completed_at, ts.h FROM ts
    UNION ALL
    SELECT v.id, v.arrived_at, v.completed_at, extract(epoch FROM (v.completed_at - v.arrived_at)) / 3600.0 AS h
    FROM visits v JOIN j ON v.job_id = j.id
    WHERE v.arrived_at IS NOT NULL AND v.completed_at IS NOT NULL AND v.completed_at > v.arrived_at AND NOT EXISTS (SELECT 1 FROM ts)),
  vt AS (
    SELECT vis.id, vis.h, concat_ws(' ', e.first_name, e.last_name) AS nm,
           nullif(coalesce(nullif(e.labour_cost_per_hour, 0), e.hourly_wage * (1 + coalesce(e.burden_pct, 0) / 100)), 0) AS rate
    FROM vis JOIN ts ON ts.id = vis.id JOIN employees e ON e.id = ts.technician_id
    UNION ALL
    SELECT vis.id, vis.h, concat_ws(' ', e.first_name, e.last_name) AS nm,
           nullif(coalesce(nullif(e.labour_cost_per_hour, 0), e.hourly_wage * (1 + coalesce(e.burden_pct, 0) / 100)), 0) AS rate
    FROM vis JOIN visit_assignments va ON va.visit_id = vis.id JOIN employees e ON e.id = va.employee_id WHERE NOT EXISTS (SELECT 1 FROM ts)),$n$);
SELECT public._patch_fn('inv_costing', $o$'job_done', j.completed_at IS NOT NULL,$o$, $n$'job_done', j.completed_at IS NOT NULL, 'from_timesheets', EXISTS (SELECT 1 FROM ts),$n$);
NOTIFY pgrst, 'reload schema';

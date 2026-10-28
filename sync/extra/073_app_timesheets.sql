-- Timesheets in our own system: when a tech's call goes On the way / Arrived / Done in the app, each tech on that call gets
-- the same kind of timesheet ServiceTitan keeps (dispatched / arrived / done). ServiceTitan's own calls keep ServiceTitan's timesheets.
ALTER TABLE public.job_timesheets ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'st';
CREATE SEQUENCE IF NOT EXISTS public.app_timesheet_seq START 900000000000000;
CREATE UNIQUE INDEX IF NOT EXISTS job_timesheets_app_uq ON public.job_timesheets (visit_id, technician_id) WHERE source = 'app';

CREATE OR REPLACE FUNCTION public._app_timesheets(p_visit bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v visits;
BEGIN
  SELECT * INTO v FROM visits WHERE id = p_visit;
  IF v.id IS NULL OR v.id < 10000000000 THEN RETURN; END IF;   -- ServiceTitan's calls: its own timesheets come with the sync
  INSERT INTO job_timesheets (id, job_id, visit_id, technician_id, dispatched_on, arrived_on, done_on, canceled_on, active, modified_on, source)
  SELECT nextval('app_timesheet_seq'), v.job_id, v.id, va.employee_id, v.en_route_at, v.arrived_at,
         CASE WHEN v.status IN ('completed', 'needs_return') THEN v.completed_at END,
         CASE WHEN v.status = 'cancelled' THEN coalesce(v.completed_at, now()) END, true, now(), 'app'
  FROM visit_assignments va WHERE va.visit_id = v.id
  ON CONFLICT (visit_id, technician_id) WHERE source = 'app' DO UPDATE SET
    job_id = EXCLUDED.job_id,
    dispatched_on = EXCLUDED.dispatched_on,
    arrived_on = EXCLUDED.arrived_on,
    done_on = EXCLUDED.done_on,
    canceled_on = EXCLUDED.canceled_on,
    modified_on = now();
  -- a tech taken off the call: their timesheet goes (unless they already did time on it)
  DELETE FROM job_timesheets t WHERE t.source = 'app' AND t.visit_id = v.id AND t.arrived_on IS NULL
    AND NOT EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id = v.id AND va.employee_id = t.technician_id);
END $function$;

CREATE OR REPLACE FUNCTION public._trg_app_timesheets() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF TG_TABLE_NAME = 'visits' THEN PERFORM public._app_timesheets(NEW.id);
  ELSE PERFORM public._app_timesheets(coalesce(NEW.visit_id, OLD.visit_id)); END IF;
  RETURN NULL;
END $function$;
DROP TRIGGER IF EXISTS app_timesheets ON public.visits;
CREATE TRIGGER app_timesheets AFTER INSERT OR UPDATE OF status, en_route_at, arrived_at, completed_at, job_id ON public.visits
  FOR EACH ROW EXECUTE FUNCTION public._trg_app_timesheets();
DROP TRIGGER IF EXISTS app_timesheets ON public.visit_assignments;
CREATE TRIGGER app_timesheets AFTER INSERT OR DELETE ON public.visit_assignments
  FOR EACH ROW EXECUTE FUNCTION public._trg_app_timesheets();
REVOKE EXECUTE ON FUNCTION public._app_timesheets(bigint), public._trg_app_timesheets() FROM PUBLIC, anon, authenticated;

-- every app call already worked on gets its timesheets (once; safe to repeat)
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT v.id FROM visits v WHERE v.id >= 10000000000 AND (v.en_route_at IS NOT NULL OR v.arrived_at IS NOT NULL OR v.completed_at IS NOT NULL)
             AND NOT EXISTS (SELECT 1 FROM job_timesheets t WHERE t.visit_id = v.id AND t.source = 'app') LOOP
    PERFORM public._app_timesheets(r.id);
  END LOOP;
END $$;

-- a job's timesheets, for the customer page
CREATE OR REPLACE FUNCTION public.job_timesheets_list(p_job bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'tech', coalesce(nullif(concat_ws(' ', e.first_name, e.last_name), ''), 'Tech #' || t.technician_id),
      'dispatched', t.dispatched_on, 'arrived', t.arrived_on, 'done', t.done_on, 'canceled', t.canceled_on, 'source', t.source,
      'hours', CASE WHEN t.arrived_on IS NOT NULL AND t.done_on > t.arrived_on THEN round((extract(epoch FROM (t.done_on - t.arrived_on)) / 3600.0)::numeric, 2) END,
      'drive', CASE WHEN t.dispatched_on IS NOT NULL AND t.arrived_on > t.dispatched_on THEN round((extract(epoch FROM (t.arrived_on - t.dispatched_on)) / 3600.0)::numeric, 2) END)
      ORDER BY coalesce(t.dispatched_on, t.arrived_on), t.id)
    FROM job_timesheets t LEFT JOIN employees e ON e.id = t.technician_id
    WHERE t.job_id = p_job AND t.active), '[]'::jsonb);
END $function$;
REVOKE EXECUTE ON FUNCTION public.job_timesheets_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.job_timesheets_list(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- ServiceTitan non-job appointments: time booked on a tech's schedule that isn't a job (e.g. "Tire N Rim City", "George needs you").
-- The sync keeps them (180 days back, 60 ahead). Payroll counts them as paid hours.
CREATE TABLE IF NOT EXISTS public.st_nonjob_appts (
  id bigint PRIMARY KEY, technician_id bigint, starts_at timestamptz, duration_min integer, name text, summary text,
  timesheet_code_id bigint, all_day boolean, active boolean, synced_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS st_nonjob_appts_tech_day ON public.st_nonjob_appts (technician_id, starts_at);
ALTER TABLE public.st_nonjob_appts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.st_nonjob_appts FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.payroll_nonjob(p_user bigint, p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_emp bigint;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' AND p_user IS DISTINCT FROM public.current_app_user_id() THEN RETURN '[]'::jsonb; END IF;
  SELECT employee_id INTO v_emp FROM app_users WHERE id = p_user; IF v_emp IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', n.id, 'day', (n.starts_at AT TIME ZONE 'America/Toronto')::date, 'start', n.starts_at,
      'minutes', n.duration_min, 'name', n.name, 'summary', n.summary, 'all_day', n.all_day) ORDER BY n.starts_at)
    FROM public.st_nonjob_appts n WHERE n.technician_id = ANY (public._payroll_emp_ids(v_emp)) AND COALESCE(n.active, true)
      AND (n.starts_at AT TIME ZONE 'America/Toronto')::date BETWEEN p_from AND p_to), '[]'::jsonb);
END $function$;
REVOKE EXECUTE ON FUNCTION public.payroll_nonjob(bigint, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_nonjob(bigint, date, date) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- How long each kind of job is given (Book a call → Reid → Maintenance: the time under each button). Kept here, so the nightly
-- ServiceTitan sync never changes it. Used for the booking's length (and so the call's length on the dispatch board) and online booking.
-- Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.job_type_minutes (job_type_id bigint PRIMARY KEY, minutes int NOT NULL CHECK (minutes BETWEEN 5 AND 1440), set_by text, set_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.job_type_minutes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.job_type_minutes FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.job_type_minutes_get() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id', job_type_id, 'minutes', minutes)) FROM job_type_minutes), '[]'::jsonb) END $f$;
CREATE OR REPLACE FUNCTION public.job_type_minutes_set(p_type bigint, p_minutes int) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (public.current_staff_role() = 'owner' OR public.has_permission('calls.dispatch')) THEN RAISE EXCEPTION 'Only owners and dispatch can change how long a job is given'; END IF;
  IF p_minutes IS NULL THEN DELETE FROM job_type_minutes WHERE job_type_id = p_type; RETURN; END IF;
  INSERT INTO job_type_minutes (job_type_id, minutes, set_by) VALUES (p_type, p_minutes, auth.jwt() ->> 'email')
  ON CONFLICT (job_type_id) DO UPDATE SET minutes = EXCLUDED.minutes, set_by = EXCLUDED.set_by, set_at = now();
END $function$;
REVOKE EXECUTE ON FUNCTION public.job_type_minutes_get(), public.job_type_minutes_set(bigint, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.job_type_minutes_get(), public.job_type_minutes_set(bigint, int) TO authenticated;
NOTIFY pgrst, 'reload schema';

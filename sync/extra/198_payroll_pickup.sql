-- Payroll: time added to a tech's day that isn't a call, e.g. picking up equipment at the office before a day that starts with an install.
-- The app adds 30 minutes on its own; an owner can approve it or change the minutes. Owners only.
CREATE TABLE IF NOT EXISTS public.payroll_day_extras (
  app_user_id bigint NOT NULL, day date NOT NULL, kind text NOT NULL DEFAULT 'pickup',
  minutes integer NOT NULL CHECK (minutes >= 0 AND minutes <= 600), approved boolean NOT NULL DEFAULT false,
  set_by text, set_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (app_user_id, day, kind));
ALTER TABLE public.payroll_day_extras ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_day_extras FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.payroll_extras(p_user bigint, p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RETURN '[]'::jsonb; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('day', day, 'kind', kind, 'minutes', minutes, 'approved', approved, 'set_by', set_by, 'set_at', set_at))
    FROM public.payroll_day_extras WHERE app_user_id = p_user AND day BETWEEN p_from AND p_to), '[]'::jsonb);
END $function$;

CREATE OR REPLACE FUNCTION public.payroll_extra_set(p_user bigint, p_day date, p_kind text, p_minutes integer, p_approved boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  INSERT INTO public.payroll_day_extras (app_user_id, day, kind, minutes, approved, set_by, set_at)
  VALUES (p_user, p_day, COALESCE(p_kind, 'pickup'), p_minutes, p_approved, auth.jwt() ->> 'email', now())
  ON CONFLICT (app_user_id, day, kind) DO UPDATE SET minutes = EXCLUDED.minutes, approved = EXCLUDED.approved, set_by = EXCLUDED.set_by, set_at = now();
END $function$;
REVOKE EXECUTE ON FUNCTION public.payroll_extras(bigint, date, date), public.payroll_extra_set(bigint, date, text, integer, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_extras(bigint, date, date), public.payroll_extra_set(bigint, date, text, integer, boolean) TO authenticated;
NOTIFY pgrst, 'reload schema';

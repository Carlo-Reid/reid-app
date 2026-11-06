-- Payroll: when the pick-up time is changed from the 30 minutes the app adds, the reason has to be given and is kept with it.
ALTER TABLE public.payroll_day_extras ADD COLUMN IF NOT EXISTS reason text;
DROP FUNCTION IF EXISTS public.payroll_extra_set(bigint, date, text, integer, boolean);
CREATE OR REPLACE FUNCTION public.payroll_extra_set(p_user bigint, p_day date, p_kind text, p_minutes integer, p_approved boolean, p_reason text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  IF p_minutes <> 30 AND COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Say why the time is different from 30 minutes'; END IF;
  INSERT INTO public.payroll_day_extras (app_user_id, day, kind, minutes, approved, reason, set_by, set_at)
  VALUES (p_user, p_day, COALESCE(p_kind, 'pickup'), p_minutes, p_approved, NULLIF(btrim(p_reason), ''), auth.jwt() ->> 'email', now())
  ON CONFLICT (app_user_id, day, kind) DO UPDATE SET minutes = EXCLUDED.minutes, approved = EXCLUDED.approved, reason = EXCLUDED.reason, set_by = EXCLUDED.set_by, set_at = now();
END $function$;
CREATE OR REPLACE FUNCTION public.payroll_extras(p_user bigint, p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RETURN '[]'::jsonb; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('day', day, 'kind', kind, 'minutes', minutes, 'approved', approved, 'reason', reason, 'set_by', set_by, 'set_at', set_at))
    FROM public.payroll_day_extras WHERE app_user_id = p_user AND day BETWEEN p_from AND p_to), '[]'::jsonb);
END $function$;
REVOKE EXECUTE ON FUNCTION public.payroll_extra_set(bigint, date, text, integer, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_extra_set(bigint, date, text, integer, boolean, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

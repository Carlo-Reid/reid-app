-- Payroll: events on the schedule aren't paid until someone adds them (techs also book unpaid time as events).
-- The tech (for their own) or an owner marks each one paid or not.
CREATE TABLE IF NOT EXISTS public.payroll_nonjob_pay (
  app_user_id bigint NOT NULL, nonjob_id bigint NOT NULL, paid boolean NOT NULL, set_by text, set_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (app_user_id, nonjob_id));
ALTER TABLE public.payroll_nonjob_pay ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_nonjob_pay FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.payroll_nonjob(p_user bigint, p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_emp bigint;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' AND p_user IS DISTINCT FROM public.current_app_user_id() THEN RETURN '[]'::jsonb; END IF;
  SELECT employee_id INTO v_emp FROM app_users WHERE id = p_user; IF v_emp IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', n.id, 'day', (n.starts_at AT TIME ZONE 'America/Toronto')::date, 'start', n.starts_at,
      'minutes', n.duration_min, 'name', n.name, 'summary', n.summary, 'all_day', n.all_day, 'paid', COALESCE(pp.paid, false), 'paid_by', pp.set_by) ORDER BY n.starts_at)
    FROM public.st_nonjob_appts n LEFT JOIN public.payroll_nonjob_pay pp ON pp.app_user_id = p_user AND pp.nonjob_id = n.id
    WHERE n.technician_id = ANY (public._payroll_emp_ids(v_emp)) AND COALESCE(n.active, true)
      AND (n.starts_at AT TIME ZONE 'America/Toronto')::date BETWEEN p_from AND p_to), '[]'::jsonb);
END $function$;

CREATE OR REPLACE FUNCTION public.payroll_nonjob_set(p_user bigint, p_id bigint, p_paid boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._payroll_can(p_user) THEN RAISE EXCEPTION 'You can only change your own payroll'; END IF;
  INSERT INTO public.payroll_nonjob_pay (app_user_id, nonjob_id, paid, set_by, set_at) VALUES (p_user, p_id, p_paid, auth.jwt() ->> 'email', now())
  ON CONFLICT (app_user_id, nonjob_id) DO UPDATE SET paid = EXCLUDED.paid, set_by = EXCLUDED.set_by, set_at = now();
END $function$;
REVOKE EXECUTE ON FUNCTION public.payroll_nonjob_set(bigint, bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_nonjob_set(bigint, bigint, boolean) TO authenticated;
NOTIFY pgrst, 'reload schema';

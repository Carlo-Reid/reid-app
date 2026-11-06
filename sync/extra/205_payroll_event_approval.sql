-- Payroll: when a tech adds a schedule event to his own pay it waits for an owner to approve it (shown on the owner's Tasks page).
-- approved: true = counts, NULL = waiting for approval. An owner adding it approves it at once.
ALTER TABLE public.payroll_nonjob_pay ADD COLUMN IF NOT EXISTS approved boolean;
ALTER TABLE public.payroll_nonjob_pay ADD COLUMN IF NOT EXISTS approved_by text;
ALTER TABLE public.payroll_nonjob_pay ADD COLUMN IF NOT EXISTS approved_at timestamptz;
-- ones added before this: an owner's count, a tech's wait
UPDATE public.payroll_nonjob_pay p SET approved = true, approved_by = p.set_by, approved_at = p.set_at
 WHERE p.approved IS NULL AND p.paid AND EXISTS (SELECT 1 FROM public.app_users u WHERE u.role = 'owner' AND lower(u.login_email::text) = lower(coalesce(p.set_by, '')));

CREATE OR REPLACE FUNCTION public.payroll_nonjob(p_user bigint, p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_emp bigint;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' AND p_user IS DISTINCT FROM public.current_app_user_id() THEN RETURN '[]'::jsonb; END IF;
  SELECT employee_id INTO v_emp FROM app_users WHERE id = p_user; IF v_emp IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', n.id, 'day', (n.starts_at AT TIME ZONE 'America/Toronto')::date, 'start', n.starts_at,
      'minutes', n.duration_min, 'name', n.name, 'summary', n.summary, 'all_day', n.all_day, 'paid', COALESCE(pp.paid, false), 'paid_by', pp.set_by,
      'approved', CASE WHEN COALESCE(pp.paid, false) THEN pp.approved END, 'approved_by', pp.approved_by) ORDER BY n.starts_at)
    FROM public.st_nonjob_appts n LEFT JOIN public.payroll_nonjob_pay pp ON pp.app_user_id = p_user AND pp.nonjob_id = n.id
    WHERE n.technician_id = ANY (public._payroll_emp_ids(v_emp)) AND COALESCE(n.active, true)
      AND (n.starts_at AT TIME ZONE 'America/Toronto')::date BETWEEN p_from AND p_to), '[]'::jsonb);
END $function$;

-- a tech adding it to pay: waits; an owner: approved
CREATE OR REPLACE FUNCTION public.payroll_nonjob_set(p_user bigint, p_id bigint, p_paid boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_owner boolean := public.current_staff_role() = 'owner'; v_ok boolean;
BEGIN
  IF NOT public._payroll_can(p_user) THEN RAISE EXCEPTION 'You can only change your own payroll'; END IF;
  v_ok := CASE WHEN p_paid AND v_owner THEN true END;
  INSERT INTO public.payroll_nonjob_pay (app_user_id, nonjob_id, paid, set_by, set_at, approved, approved_by, approved_at)
  VALUES (p_user, p_id, p_paid, auth.jwt() ->> 'email', now(), v_ok, CASE WHEN v_ok THEN auth.jwt() ->> 'email' END, CASE WHEN v_ok THEN now() END)
  ON CONFLICT (app_user_id, nonjob_id) DO UPDATE SET paid = EXCLUDED.paid, set_by = EXCLUDED.set_by, set_at = now(),
    approved = EXCLUDED.approved, approved_by = EXCLUDED.approved_by, approved_at = EXCLUDED.approved_at;
END $function$;

-- owner: approve it (counts) or not (not paid)
CREATE OR REPLACE FUNCTION public.payroll_nonjob_approve(p_user bigint, p_id bigint, p_ok boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only owners can approve'; END IF;
  UPDATE public.payroll_nonjob_pay SET paid = p_ok, approved = CASE WHEN p_ok THEN true END,
    approved_by = auth.jwt() ->> 'email', approved_at = now() WHERE app_user_id = p_user AND nonjob_id = p_id;
END $function$;

-- owner's Tasks page: everything on payroll waiting for approval (schedule events techs added to pay, events added by hand)
CREATE OR REPLACE FUNCTION public.payroll_waiting() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RETURN '[]'::jsonb; END IF;
  RETURN COALESCE((SELECT jsonb_agg(x ORDER BY x ->> 'start') FROM (
    SELECT jsonb_build_object('kind', 'nj', 'id', n.id, 'user', pp.app_user_id, 'tech', public._staff_name(pp.app_user_id),
        'day', (n.starts_at AT TIME ZONE 'America/Toronto')::date, 'start', n.starts_at, 'minutes', n.duration_min, 'name', n.name, 'asked_at', pp.set_at) AS x
      FROM public.payroll_nonjob_pay pp JOIN public.st_nonjob_appts n ON n.id = pp.nonjob_id WHERE pp.paid AND pp.approved IS NULL
    UNION ALL
    SELECT jsonb_build_object('kind', 'ev', 'id', e.id, 'user', e.app_user_id, 'tech', public._staff_name(e.app_user_id),
        'day', e.day, 'start', (e.day + e.starts) AT TIME ZONE 'America/Toronto', 'minutes', round(extract(epoch FROM e.ends - e.starts) / 60), 'name', e.what, 'asked_at', e.added_at)
      FROM public.payroll_events e WHERE NOT e.approved) s), '[]'::jsonb);
END $function$;
REVOKE EXECUTE ON FUNCTION public.payroll_nonjob_approve(bigint, bigint, boolean), public.payroll_waiting() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_nonjob_approve(bigint, bigint, boolean), public.payroll_waiting() TO authenticated;
NOTIFY pgrst, 'reload schema';

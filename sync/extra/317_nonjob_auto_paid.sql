-- Payroll (Carlo, Nov 17, 2026): a note on a tech's schedule is paid time by itself, unless the note says he is booked off.
-- The page has to tell "nobody has said anything about this note" (paid by the rule) from "a person said Not paid" (removed).
-- 'decided' = a person pressed Add to pay or Remove for this note. Nothing else changed in this function.
CREATE OR REPLACE FUNCTION public.payroll_nonjob(p_user bigint, p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_emp bigint;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' AND p_user IS DISTINCT FROM public.current_app_user_id() THEN RETURN '[]'::jsonb; END IF;
  SELECT employee_id INTO v_emp FROM app_users WHERE id = p_user; IF v_emp IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', n.id, 'day', (n.starts_at AT TIME ZONE 'America/Toronto')::date, 'start', n.starts_at,
      'minutes', n.duration_min, 'name', n.name, 'summary', n.summary, 'all_day', n.all_day, 'paid', COALESCE(pp.paid, false), 'paid_by', pp.set_by,
      'approved', CASE WHEN COALESCE(pp.paid, false) THEN pp.approved END, 'approved_by', pp.approved_by,
      'decided', pp.nonjob_id IS NOT NULL) ORDER BY n.starts_at)
    FROM public.st_nonjob_appts n LEFT JOIN public.payroll_nonjob_pay pp ON pp.app_user_id = p_user AND pp.nonjob_id = n.id
    WHERE n.technician_id = ANY (public._payroll_emp_ids(v_emp)) AND COALESCE(n.active, true)
      AND (n.starts_at AT TIME ZONE 'America/Toronto')::date BETWEEN p_from AND p_to), '[]'::jsonb);
END $function$;
REVOKE EXECUTE ON FUNCTION public.payroll_nonjob(bigint, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_nonjob(bigint, date, date) TO authenticated;
NOTIFY pgrst, 'reload schema';

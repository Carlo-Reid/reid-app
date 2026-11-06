-- A call the tech forgot to close: he arrived but never pressed Done (in ServiceTitan), and it's from an earlier day or he arrived 10+ hours ago.
-- my_open_calls: the signed-in person's own, for the warning that stays on screen until it's closed.
CREATE OR REPLACE FUNCTION public.my_open_calls() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_emp bigint;
BEGIN
  SELECT employee_id INTO v_emp FROM app_users WHERE id = public.current_app_user_id(); IF v_emp IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('visit', t.visit_id, 'arrived', t.arrived_on, 'job_number', j.job_number, 'customer', c.display_name,
        'address', concat_ws(', ', nullif(l.street, ''), nullif(l.city, ''))) ORDER BY t.arrived_on)
    FROM public.job_timesheets t
    LEFT JOIN visits v ON v.id = t.visit_id LEFT JOIN jobs j ON j.id = t.job_id LEFT JOIN locations l ON l.id = j.location_id
    LEFT JOIN customers c ON c.id = coalesce(j.customer_id, l.customer_id)
    WHERE t.technician_id = ANY (public._payroll_emp_ids(v_emp)) AND coalesce(t.active, true)
      AND t.arrived_on IS NOT NULL AND t.done_on IS NULL AND t.canceled_on IS NULL
      AND t.arrived_on > now() - interval '30 days'
      AND ((t.arrived_on AT TIME ZONE 'America/Toronto')::date < (now() AT TIME ZONE 'America/Toronto')::date OR t.arrived_on < now() - interval '10 hours')
      AND coalesce(v.status, '') NOT IN ('completed', 'cancelled')
      AND NOT EXISTS (SELECT 1 FROM public.job_timesheets t2 WHERE t2.visit_id = t.visit_id AND t2.technician_id = t.technician_id AND t2.done_on > t.arrived_on AND coalesce(t2.active, true))), '[]'::jsonb);
END $function$;
REVOKE EXECUTE ON FUNCTION public.my_open_calls() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_open_calls() TO authenticated;
NOTIFY pgrst, 'reload schema';

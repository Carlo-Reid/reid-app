-- A sales person's own booked calls (today on, plus any from the last 3 days not done yet), for the "My booked calls" page.
-- Owners can look at anyone's by passing p_employee.
CREATE OR REPLACE FUNCTION public.my_booked_calls(p_employee bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_emp bigint := CASE WHEN p_employee IS NOT NULL AND (public.current_staff_role() = 'owner' OR public.has_permission('calls.dispatch')) THEN p_employee ELSE public._my_employee() END;
        v_today date := (now() AT TIME ZONE 'America/Toronto')::date;
BEGIN
  IF public.current_staff_role() IS NULL OR v_emp IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x->>'day', x->>'from' NULLS LAST) FROM (
    SELECT jsonb_build_object('visit', v.id, 'job', j.id, 'job_number', j.job_number, 'day', v.scheduled_date, 'from', v.arrival_start, 'to', v.arrival_end,
      'status', v.status, 'kind', j.sales_kind, 'on_site', j.sales_on_site_at, 'summary', j.summary,
      'customer_id', j.customer_id, 'customer', coalesce(c.display_name, c.company_name), 'street', l.street, 'unit', l.unit, 'city', l.city, 'access', l.access_notes,
      'est_id', (SELECT max(e.id) FROM estimates e WHERE e.job_id = j.id AND e.cancelled_at IS NULL),
      'est_number', (SELECT e.estimate_number FROM estimates e WHERE e.id = (SELECT max(e2.id) FROM estimates e2 WHERE e2.job_id = j.id AND e2.cancelled_at IS NULL))) x
    FROM visits v JOIN visit_assignments va ON va.visit_id = v.id AND va.employee_id = v_emp
    JOIN jobs j ON j.id = v.job_id LEFT JOIN customers c ON c.id = j.customer_id LEFT JOIN locations l ON l.id = j.location_id
    WHERE v.scheduled_date BETWEEN v_today - 3 AND v_today + 60 AND v.status NOT IN ('cancelled', 'completed')
      AND (v.scheduled_date >= v_today OR v.status <> 'completed') AND j.sales_cancelled_at IS NULL AND j.status IS DISTINCT FROM 'cancelled') s), '[]'::jsonb);
END $function$;
REVOKE EXECUTE ON FUNCTION public.my_booked_calls(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_booked_calls(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

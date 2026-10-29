-- Section 1, Plans box: for each plan at an address, the last time we did that plan's work (and the next one booked).
-- A job counts for a plan when it is tied to the plan (a plan visit, or an invoice line for the plan), when its job type is
-- for the same kind of equipment (fireplace, pool heater, A/C, furnace, boiler, HRV, water heater, security…), or when the
-- job's notes name the plan's code (for example "CCP").
CREATE OR REPLACE FUNCTION public._svc_cats(p text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $function$
  SELECT array_remove(ARRAY[
    CASE WHEN p ~* 'fire\s*place|\mgfp\M|\mcfp\M' THEN 'fireplace' END,
    CASE WHEN p ~* 'pool' THEN 'pool' END,
    CASE WHEN p ~* 'boiler' THEN 'boiler' END,
    CASE WHEN p ~* 'a/c|\mac\M|air\s*cond|cooling|heat\s*pump' THEN 'ac' END,
    CASE WHEN p ~* 'furnace' THEN 'furnace' END,
    CASE WHEN p ~* 'hrv|erv' THEN 'hrv' END,
    CASE WHEN p ~* 'water\s*heater|hot\s*water|\mhwt\M|tankless' THEN 'water' END,
    CASE WHEN p ~* 'humidifier' THEN 'humid' END,
    CASE WHEN p ~* 'generator' THEN 'gen' END,
    CASE WHEN p ~* 'security|monitor|alarm' THEN 'security' END,
    CASE WHEN p ~* 'duct' THEN 'duct' END], NULL)
$function$;

CREATE OR REPLACE FUNCTION public.plan_last_service(p_location bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_out jsonb := '[]'; m record; v_last record; v_next date; v_code text; v_cats text[];
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN NULL; END IF;
  FOR m IN SELECT ms.id, ms.status, pt.name FROM memberships ms JOIN plan_types pt ON pt.id = ms.plan_type_id
           WHERE ms.location_id = p_location AND ms.status = 'active' ORDER BY pt.name LOOP
    v_code := lower(btrim(split_part(m.name, ' - ', 1))); v_cats := public._svc_cats(m.name);
    IF v_code = lower(btrim(m.name)) OR v_code !~ '^[a-z0-9]{2,8}$' THEN v_code := NULL; END IF;
    WITH c AS (
      SELECT j.id, j.job_number, j.status, jt.name AS jtype,
        coalesce(j.completed_at::date, (SELECT max(v.scheduled_date) FROM visits v WHERE v.job_id = j.id AND v.status = 'completed')) AS done_on,
        CASE WHEN EXISTS (SELECT 1 FROM membership_visits mv WHERE mv.membership_id = m.id AND mv.job_id = j.id)
               OR EXISTS (SELECT 1 FROM invoice_lines il JOIN invoices i ON i.id = il.invoice_id WHERE i.job_id = j.id AND il.membership_id = m.id) THEN 'plan'
             WHEN cardinality(v_cats) > 0 AND public._svc_cats(coalesce(jt.name, '')) && v_cats THEN 'type'
             WHEN v_code IS NOT NULL AND lower(coalesce(j.summary, '') || ' ' || coalesce(j.description, '')) ~ ('\m' || v_code || '\M') THEN 'notes' END AS how
      FROM jobs j LEFT JOIN job_types jt ON jt.id = j.job_type_id
      WHERE j.location_id = p_location AND j.status <> 'cancelled')
    SELECT * INTO v_last FROM c WHERE how IS NOT NULL AND (status = 'completed' OR done_on IS NOT NULL) AND done_on IS NOT NULL ORDER BY done_on DESC LIMIT 1;
    SELECT min(v.scheduled_date) INTO v_next FROM jobs j JOIN visits v ON v.job_id = j.id LEFT JOIN job_types jt ON jt.id = j.job_type_id
      WHERE j.location_id = p_location AND j.status NOT IN ('cancelled', 'completed') AND v.status NOT IN ('cancelled', 'completed') AND v.scheduled_date >= current_date
        AND (EXISTS (SELECT 1 FROM membership_visits mv WHERE mv.membership_id = m.id AND mv.job_id = j.id)
             OR (cardinality(v_cats) > 0 AND public._svc_cats(coalesce(jt.name, '')) && v_cats)
             OR (v_code IS NOT NULL AND lower(coalesce(j.summary, '') || ' ' || coalesce(j.description, '')) ~ ('\m' || v_code || '\M')));
    v_out := v_out || jsonb_build_object('membership_id', m.id, 'plan', m.name, 'last', v_last.done_on, 'job_number', v_last.job_number,
      'job_type', v_last.jtype, 'how', v_last.how, 'next', v_next);
  END LOOP;
  RETURN v_out;
END $function$;
REVOKE EXECUTE ON FUNCTION public.plan_last_service(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.plan_last_service(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

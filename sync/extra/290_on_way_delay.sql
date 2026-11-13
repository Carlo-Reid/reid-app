-- Tech Calls: "I got delayed" on a call that is On the way (Carlo, Nov 13, 2026: "have a way to reset it and it sends a message to the customer saying
-- sorry I got delayed but I will be there soon"). The Edge Function on-way-text (delayed: true) asks on_way_delay_info, texts the customer, then
-- _on_way_delay_sent forgets the first On my way text, so the next On my way texts the customer again. The app then puts the call back to Booked.
CREATE TABLE IF NOT EXISTS public.on_way_delays (
  id bigserial PRIMARY KEY, visit_id bigint NOT NULL, at timestamptz NOT NULL DEFAULT now(), phone text, tech text, test_to text, by_user bigint);
CREATE INDEX IF NOT EXISTS on_way_delays_visit ON public.on_way_delays (visit_id, at DESC);
ALTER TABLE public.on_way_delays ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.on_way_delays FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.on_way_delay_info(p_visit bigint) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_user bigint := public.current_app_user_id(); v_role text := public.current_staff_role(); v_emp bigint; v_tech bigint; v_cust bigint; v_status text;
  v_phone text; v_name text; v_test text; v_test2 text; v_co text;
BEGIN
  IF v_user IS NULL OR v_role IS NULL THEN RETURN jsonb_build_object('error', 'not_allowed'); END IF;
  SELECT employee_id INTO v_emp FROM app_users WHERE id = v_user;
  SELECT j.customer_id, v.status INTO v_cust, v_status FROM visits v JOIN jobs j ON j.id = v.job_id WHERE v.id = p_visit;
  IF v_cust IS NULL THEN RETURN jsonb_build_object('error', 'no_call'); END IF;
  IF v_status IS DISTINCT FROM 'en_route' THEN RETURN jsonb_build_object('error', 'not_on_way'); END IF;
  SELECT va.employee_id INTO v_tech FROM visit_assignments va WHERE va.visit_id = p_visit ORDER BY (va.employee_id IS DISTINCT FROM v_emp), (va.role <> 'lead'), va.id LIMIT 1;
  IF v_tech IS NULL THEN RETURN jsonb_build_object('error', 'no_tech'); END IF;
  IF v_tech IS DISTINCT FROM v_emp AND v_role NOT IN ('owner', 'admin', 'office', 'dispatcher') THEN RETURN jsonb_build_object('error', 'not_allowed'); END IF;
  SELECT public._podium_digits(cc.value) INTO v_phone FROM customer_contacts cc
    WHERE cc.customer_id = v_cust AND cc.kind IN ('phone', 'mobile') AND length(public._podium_digits(cc.value)) = 10
      AND NOT EXISTS (SELECT 1 FROM customer_contacts x WHERE x.kind IN ('phone', 'mobile') AND public._podium_digits(x.value) = public._podium_digits(cc.value) AND x.allow_sms IS FALSE)
    ORDER BY (cc.kind = 'mobile') DESC, cc.is_primary DESC NULLS LAST, cc.id LIMIT 1;
  IF v_phone IS NULL THEN RETURN jsonb_build_object('error', 'no_phone'); END IF;
  SELECT nullif(btrim(e.first_name), '') INTO v_name FROM employees e WHERE e.id = v_tech;
  SELECT CASE WHEN nullif(btrim(send_test_to), '') IS NOT NULL THEN coalesce(public._podium_digits(send_test_phone), public._podium_digits(public._app_user_phone(v_user)), 'none') END,
         nullif(btrim(company_name), ''), public._podium_digits(send_test_phone2) INTO v_test, v_co, v_test2 FROM company_settings LIMIT 1;
  IF v_test IS NULL OR length(coalesce(v_test2, '')) <> 10 OR v_test2 = v_test THEN v_test2 := NULL; END IF;
  RETURN jsonb_build_object('user', v_user, 'customer', v_cust, 'phone', v_phone, 'tech', v_name, 'company', v_co, 'test_to', v_test, 'test_to2', v_test2);
END $f$;

CREATE OR REPLACE FUNCTION public._on_way_delay_sent(p_visit bigint, p_user bigint, p jsonb) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_job bigint;
BEGIN
  INSERT INTO on_way_delays (visit_id, phone, tech, test_to, by_user) VALUES (p_visit, p ->> 'phone', p ->> 'tech', nullif(p ->> 'test_to', ''), p_user);
  DELETE FROM on_way_texts WHERE visit_id = p_visit;                                   -- so the next On my way texts the customer again
  UPDATE visits SET customer_notified_at = NULL WHERE id = p_visit RETURNING job_id INTO v_job;
  IF v_job IS NOT NULL THEN
    INSERT INTO notes (entity_type, entity_id, body, author_user_id)
      VALUES ('job', v_job, 'Delayed text sent to the customer: ' || coalesce(p ->> 'tech', 'the tech') || ' got delayed and will be there soon'
        || CASE WHEN nullif(p ->> 'test_to', '') IS NOT NULL THEN ' (test mode: it went to the test number, not the customer)' ELSE '' END || '.', p_user);
  END IF;
END $f$;

-- the dispatch board: the calls of one day whose customer got the On my way text, or the delayed text (no On my way text since)
CREATE OR REPLACE FUNCTION public.on_way_texts_for(p_date date) RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(x.o) FROM (
    SELECT jsonb_build_object('visit_id', t.visit_id, 'at', t.at, 'minutes', t.minutes, 'pic', t.with_pic, 'test', t.test_to IS NOT NULL) AS o
      FROM on_way_texts t JOIN visits v ON v.id = t.visit_id WHERE v.scheduled_date = p_date
    UNION ALL
    SELECT jsonb_build_object('visit_id', d.visit_id, 'delayed_at', d.at, 'test', d.test_to IS NOT NULL)
      FROM (SELECT DISTINCT ON (visit_id) * FROM on_way_delays ORDER BY visit_id, at DESC) d JOIN visits v ON v.id = d.visit_id
      WHERE v.scheduled_date = p_date AND NOT EXISTS (SELECT 1 FROM on_way_texts t WHERE t.visit_id = d.visit_id)) x), '[]'::jsonb) END $f$;

REVOKE EXECUTE ON FUNCTION public.on_way_delay_info(bigint), public._on_way_delay_sent(bigint, bigint, jsonb), public.on_way_texts_for(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.on_way_delay_info(bigint), public.on_way_texts_for(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public._on_way_delay_sent(bigint, bigint, jsonb) TO service_role;
NOTIFY pgrst, 'reload schema';

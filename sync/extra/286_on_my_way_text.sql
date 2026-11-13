-- Tech Calls: "On my way" texts the customer (Carlo, Nov 13, 2026): the tech's first name, about how many minutes (from how far he is), and his picture.
-- The text is sent by the Edge Function `podium` (action on_way), which asks on_way_text_info first and writes on_way_texts after.
-- One text for each call (visits.customer_notified_at). Test mode (Settings: Sending to customers) sends it to the test number instead.
CREATE TABLE IF NOT EXISTS public.on_way_texts (
  visit_id bigint PRIMARY KEY, at timestamptz NOT NULL DEFAULT now(), minutes int, km numeric, phone text, tech text, with_pic boolean, test_to text, by_user bigint);
ALTER TABLE public.on_way_texts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.on_way_texts FROM PUBLIC, anon, authenticated;

-- what the function needs to send it. p_lat / p_lng: where the tech's phone is (null when the phone will not say).
CREATE OR REPLACE FUNCTION public.on_way_text_info(p_visit bigint, p_lat double precision DEFAULT NULL, p_lng double precision DEFAULT NULL) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_user bigint := public.current_app_user_id(); v_role text := public.current_staff_role(); v_emp bigint; v_tech bigint; v_cust bigint; v_lat double precision; v_lng double precision;
  v_notified timestamptz; v_status text; v_phone text; v_km numeric; v_min int; v_name text; v_img text; v_mime text; v_test text; v_test2 text; v_co text;
BEGIN
  IF v_user IS NULL OR v_role IS NULL THEN RETURN jsonb_build_object('error', 'not_allowed'); END IF;
  SELECT employee_id INTO v_emp FROM app_users WHERE id = v_user;
  SELECT j.customer_id, l.latitude, l.longitude, v.customer_notified_at, v.status INTO v_cust, v_lat, v_lng, v_notified, v_status
    FROM visits v JOIN jobs j ON j.id = v.job_id LEFT JOIN locations l ON l.id = j.location_id WHERE v.id = p_visit;
  IF v_cust IS NULL THEN RETURN jsonb_build_object('error', 'no_call'); END IF;
  -- the tech named in the text: the person pressing the button when the call is his, else the call's lead tech
  SELECT va.employee_id INTO v_tech FROM visit_assignments va WHERE va.visit_id = p_visit ORDER BY (va.employee_id IS DISTINCT FROM v_emp), (va.role <> 'lead'), va.id LIMIT 1;
  IF v_tech IS NULL THEN RETURN jsonb_build_object('error', 'no_tech'); END IF;
  IF v_tech IS DISTINCT FROM v_emp AND v_role NOT IN ('owner', 'admin', 'office', 'dispatcher') THEN RETURN jsonb_build_object('error', 'not_allowed'); END IF;
  IF v_notified IS NOT NULL OR EXISTS (SELECT 1 FROM on_way_texts WHERE visit_id = p_visit) THEN RETURN jsonb_build_object('already', true); END IF;
  IF v_status IN ('completed', 'cancelled') THEN RETURN jsonb_build_object('error', 'no_call'); END IF;
  SELECT public._podium_digits(cc.value) INTO v_phone FROM customer_contacts cc
    WHERE cc.customer_id = v_cust AND cc.kind IN ('phone', 'mobile') AND length(public._podium_digits(cc.value)) = 10
      AND NOT EXISTS (SELECT 1 FROM customer_contacts x WHERE x.kind IN ('phone', 'mobile') AND public._podium_digits(x.value) = public._podium_digits(cc.value) AND x.allow_sms IS FALSE)
    ORDER BY (cc.kind = 'mobile') DESC, cc.is_primary DESC NULLS LAST, cc.id LIMIT 1;
  IF v_phone IS NULL THEN RETURN jsonb_build_object('error', 'no_phone'); END IF;
  -- how far, in a straight line; roads are about 1.3 times that; about 40 km an hour in town; 3 minutes to get going; to the nearest 5
  IF p_lat BETWEEN -90 AND 90 AND p_lng BETWEEN -180 AND 180 AND v_lat IS NOT NULL AND v_lng IS NOT NULL THEN
    v_km := round((6371 * 2 * asin(sqrt(power(sin(radians(v_lat - p_lat) / 2), 2) + cos(radians(p_lat)) * cos(radians(v_lat)) * power(sin(radians(v_lng - p_lng) / 2), 2))))::numeric, 1);
    IF v_km <= 300 THEN v_min := greatest(5, (ceil((v_km * 1.3 / 40 * 60 + 3) / 5.0) * 5)::int); ELSE v_km := NULL; END IF;
  END IF;
  SELECT nullif(btrim(e.first_name), '') INTO v_name FROM employees e WHERE e.id = v_tech;
  SELECT p.image, p.mime INTO v_img, v_mime FROM staff_photos p JOIN app_users u ON u.id = p.app_user_id WHERE u.employee_id = v_tech LIMIT 1;
  SELECT CASE WHEN nullif(btrim(send_test_to), '') IS NOT NULL THEN coalesce(public._podium_digits(send_test_phone), public._podium_digits(public._app_user_phone(v_user)), 'none') END,
         nullif(btrim(company_name), ''), public._podium_digits(send_test_phone2) INTO v_test, v_co, v_test2 FROM company_settings LIMIT 1;
  IF v_test IS NULL OR length(coalesce(v_test2, '')) <> 10 OR v_test2 = v_test THEN v_test2 := NULL; END IF;   -- the second test number: only in test mode
  RETURN jsonb_build_object('user', v_user, 'customer', v_cust, 'phone', v_phone, 'tech', v_name, 'minutes', v_min, 'km', v_km, 'company', v_co, 'test_to', v_test, 'test_to2', v_test2, 'image', v_img, 'mime', coalesce(v_mime, 'image/jpeg'));
END $f$;

-- after the text went out: remember it (so it is sent once, and the dispatch board can show it) and write a job note
CREATE OR REPLACE FUNCTION public._on_way_text_sent(p_visit bigint, p_user bigint, p jsonb) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_job bigint;
BEGIN
  INSERT INTO on_way_texts (visit_id, minutes, km, phone, tech, with_pic, test_to, by_user)
    VALUES (p_visit, nullif(p ->> 'minutes', '')::int, nullif(p ->> 'km', '')::numeric, p ->> 'phone', p ->> 'tech', coalesce((p ->> 'pic')::boolean, false), nullif(p ->> 'test_to', ''), p_user)
    ON CONFLICT (visit_id) DO NOTHING;
  UPDATE visits SET customer_notified_at = now() WHERE id = p_visit AND customer_notified_at IS NULL RETURNING job_id INTO v_job;
  IF v_job IS NOT NULL THEN
    INSERT INTO notes (entity_type, entity_id, body, author_user_id)
      VALUES ('job', v_job, 'On my way text sent to the customer: ' || coalesce(p ->> 'tech', 'the tech') || ' is on the way'
        || CASE WHEN p ->> 'minutes' IS NOT NULL THEN ', about ' || (p ->> 'minutes') || ' minutes' ELSE '' END
        || CASE WHEN coalesce((p ->> 'pic')::boolean, false) THEN ', with his picture' ELSE '' END
        || CASE WHEN nullif(p ->> 'test_to', '') IS NOT NULL THEN ' (test mode: it went to the test number, not the customer)' ELSE '' END || '.', p_user);
  END IF;
END $f$;

-- the dispatch board's list (on_way_texts_for) is in 290_on_way_delay.sql, with the delayed texts.

REVOKE EXECUTE ON FUNCTION public.on_way_text_info(bigint, double precision, double precision), public._on_way_text_sent(bigint, bigint, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.on_way_text_info(bigint, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public._on_way_text_sent(bigint, bigint, jsonb) TO service_role;
NOTIFY pgrst, 'reload schema';

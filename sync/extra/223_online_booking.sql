-- Online booking from a marketing email: the {book_link} fill-in opens a page (no sign-in) where the customer picks a day and
-- arrival window from our availability, starting 2 weeks away. Best availability first (most free techs of the right kind,
-- a call close by that day), at most 2 per day. If none work: "please call the office to book". Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.online_booking (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  phone text, start_days int NOT NULL DEFAULT 14, end_days int NOT NULL DEFAULT 60, job_type_id bigint, max_offers int NOT NULL DEFAULT 12,
  set_by text, set_at timestamptz);
INSERT INTO public.online_booking (id) VALUES (1) ON CONFLICT DO NOTHING;
ALTER TABLE public.online_booking ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.online_booking FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS public.online_bookings (
  id bigserial PRIMARY KEY, customer_id bigint NOT NULL, job_id bigint, visit_id bigint, day date, start_at timestamptz, end_at timestamptz,
  note text, created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.online_bookings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.online_bookings FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._ob_type(p_type bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT to_jsonb(t) FROM job_types t
  WHERE t.job_class IN ('maintenance', 'service', 'warranty', 'duct_cleaning', 'inspection')
    AND (t.id = coalesce(p_type, (SELECT job_type_id FROM online_booking WHERE id = 1)) OR (coalesce(p_type, (SELECT job_type_id FROM online_booking WHERE id = 1)) IS NULL AND t.job_class = 'maintenance'))
  ORDER BY (t.id = p_type) DESC NULLS LAST, (t.name ~* '^maintenance 1') DESC, t.name LIMIT 1 $f$;

-- the open arrival windows: d, from, to, how many techs of the right kind are free, a score (best first)
CREATE OR REPLACE FUNCTION public._ob_slots(p_class text, p_from date, p_to date, p_lat numeric, p_lng numeric)
RETURNS TABLE(d date, s text, e text, cap int, score numeric) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE dd date; w text[]; ws timestamptz; we timestamptz; v_free int; v_open int; v_near boolean;
  kinds text[] := CASE p_class WHEN 'maintenance' THEN ARRAY['maintenance', 'service'] WHEN 'service' THEN ARRAY['service'] WHEN 'warranty' THEN ARRAY['service']
                    ELSE ARRAY['service', 'maintenance'] END;
BEGIN
  dd := p_from;
  WHILE dd <= p_to LOOP
    IF extract(isodow FROM dd) <= 5 THEN
      v_near := p_lat IS NOT NULL AND EXISTS (SELECT 1 FROM visits v JOIN jobs j ON j.id = v.job_id JOIN locations l ON l.id = j.location_id
        WHERE v.scheduled_date = dd AND v.status <> 'cancelled' AND l.latitude IS NOT NULL
          AND sqrt(power((l.latitude - p_lat) * 110.57, 2) + power((l.longitude - p_lng) * 111.32 * cos(radians(p_lat)), 2)) <= 5);
      FOREACH w SLICE 1 IN ARRAY ARRAY[['08:00', '11:00'], ['11:00', '14:00'], ['14:00', '17:00']] LOOP
        ws := public._local_ts(dd, w[1]); we := public._local_ts(dd, w[2]);
        SELECT count(*) INTO v_free FROM employees t
        WHERE t.active AND t.is_technician AND NOT coalesce(t.not_tech, false) AND coalesce(t.merged_into, 0) = 0 AND t.tech_kind = ANY (kinds)
          AND NOT EXISTS (SELECT 1 FROM visit_assignments va JOIN visits v ON v.id = va.visit_id
                          WHERE va.employee_id = t.id AND v.scheduled_date = dd AND v.status <> 'cancelled'
                            AND (v.arrival_start IS NULL OR (v.arrival_start < we AND coalesce(v.arrival_end, v.arrival_start + interval '1 hour') > ws)))
          AND NOT EXISTS (SELECT 1 FROM staff_blocks b WHERE b.employee_id = t.id AND b.day = dd
                            AND (b.start_time IS NULL OR (b.start_time < w[2]::time AND coalesce(b.end_time, '23:59') > w[1]::time)));
        -- calls already booked for that window with no tech yet (online bookings and the like) use up a free tech
        SELECT count(*) INTO v_open FROM visits v
        WHERE v.scheduled_date = dd AND v.status NOT IN ('cancelled', 'completed') AND v.arrival_start < we AND coalesce(v.arrival_end, v.arrival_start + interval '1 hour') > ws
          AND NOT EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id = v.id);
        IF v_free - v_open > 0 THEN
          d := dd; s := w[1]; e := w[2]; cap := v_free - v_open; score := least(cap, 4) + CASE WHEN v_near THEN 3 ELSE 0 END - (dd - p_from) * 0.02;
          RETURN NEXT;
        END IF;
      END LOOP;
    END IF;
    dd := dd + 1;
  END LOOP;
END $function$;

-- the booking page: who it's for, and the days and times we can offer
CREATE OR REPLACE FUNCTION public.public_book_info(p_token text, p_type bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE c customers; l locations; t jsonb; cfg online_booking; b online_bookings; v_today date := (now() AT TIME ZONE 'America/Toronto')::date; v_slots jsonb;
BEGIN
  SELECT * INTO cfg FROM online_booking WHERE id = 1;
  IF coalesce(btrim(p_token), '') = '' THEN RETURN jsonb_build_object('ok', false, 'phone', cfg.phone); END IF;
  SELECT * INTO c FROM customers WHERE marketing_token::text = p_token AND merged_into_id IS NULL;
  IF c.id IS NULL OR coalesce(c.do_not_contact, false) THEN RETURN jsonb_build_object('ok', false, 'phone', cfg.phone); END IF;
  SELECT * INTO l FROM locations WHERE customer_id = c.id ORDER BY (active IS NOT FALSE) DESC, id LIMIT 1;
  t := public._ob_type(p_type);
  SELECT * INTO b FROM online_bookings WHERE customer_id = c.id AND day >= v_today ORDER BY id DESC LIMIT 1;
  IF b.id IS NOT NULL AND EXISTS (SELECT 1 FROM visits WHERE id = b.visit_id AND status <> 'cancelled') THEN
    RETURN jsonb_build_object('ok', true, 'name', c.display_name, 'street', l.street, 'city', l.city, 'phone', cfg.phone,
      'booked', jsonb_build_object('day', b.day, 'start', to_char(b.start_at AT TIME ZONE 'America/Toronto', 'HH24:MI'), 'end', to_char(b.end_at AT TIME ZONE 'America/Toronto', 'HH24:MI')));
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('day', x.d, 'start', x.s, 'end', x.e) ORDER BY x.d, x.s), '[]') INTO v_slots FROM (
    SELECT * FROM (SELECT o.*, row_number() OVER (PARTITION BY o.d ORDER BY o.score DESC, o.s) AS n
                   FROM public._ob_slots(t ->> 'job_class', v_today + cfg.start_days, v_today + cfg.end_days, l.latitude, l.longitude) o) q
    WHERE n <= 2 ORDER BY score DESC, d LIMIT greatest(cfg.max_offers, 1)) x;
  RETURN jsonb_build_object('ok', true, 'name', c.display_name, 'street', l.street, 'city', l.city, 'phone', cfg.phone, 'what', t ->> 'name', 'slots', v_slots);
END $function$;

-- the customer picked one: book it (no tech yet; the office assigns it on the dispatch board). p_dry: check everything, then undo.
CREATE OR REPLACE FUNCTION public.public_book(p_token text, p_type bigint, p_day date, p_start text, p_note text DEFAULT NULL, p_dry boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE info jsonb; c customers; l locations; t jsonb; j jobs; v_end text; v_visit bigint; v_dur int; v_unit bigint;
BEGIN
  info := public.public_book_info(p_token, p_type);
  IF NOT coalesce((info ->> 'ok')::boolean, false) THEN RAISE EXCEPTION 'This booking link isn''t working. Please call the office to book.'; END IF;
  IF info ? 'booked' THEN RETURN jsonb_build_object('ok', true, 'already', true, 'booked', info -> 'booked'); END IF;
  SELECT x ->> 'end' INTO v_end FROM jsonb_array_elements(info -> 'slots') x WHERE (x ->> 'day')::date = p_day AND x ->> 'start' = p_start;
  IF v_end IS NULL THEN RAISE EXCEPTION 'Sorry, that time was just taken. Please pick another one.'; END IF;
  SELECT * INTO c FROM customers WHERE marketing_token::text = p_token;
  SELECT * INTO l FROM locations WHERE customer_id = c.id ORDER BY (active IS NOT FALSE) DESC, id LIMIT 1;
  t := public._ob_type(p_type);
  v_unit := coalesce(nullif(t ->> 'unit_id', ''), nullif(t ->> 'business_unit_id', ''), nullif(t ->> 'default_business_unit_id', ''))::bigint;
  v_dur := coalesce(nullif(t ->> 'duration', ''), nullif(t ->> 'duration_minutes', ''), nullif(t ->> 'est_duration_minutes', ''), '60')::int;
  INSERT INTO jobs (job_number, customer_id, location_id, job_type_id, business_unit_id, status, priority, summary)
  VALUES ('new', c.id, l.id, (t ->> 'id')::bigint, v_unit, 'new', 'normal', left(coalesce(t ->> 'name', 'Maintenance') || ' (booked online by the customer)', 200))
  RETURNING * INTO j;
  UPDATE jobs SET job_number = j.id::text WHERE id = j.id RETURNING * INTO j;
  INSERT INTO visits (job_id, visit_number, visit_purpose, scheduled_date, arrival_start, arrival_end, est_duration_minutes, status)
  VALUES (j.id, 1, 'Booked online by the customer', p_day, public._local_ts(p_day, p_start), public._local_ts(p_day, v_end), v_dur, 'scheduled')
  RETURNING id INTO v_visit;
  INSERT INTO online_bookings (customer_id, job_id, visit_id, day, start_at, end_at, note)
  VALUES (c.id, j.id, v_visit, p_day, public._local_ts(p_day, p_start), public._local_ts(p_day, v_end), nullif(btrim(left(p_note, 1000)), ''));
  BEGIN
    INSERT INTO job_status_history (job_id, from_status, to_status, note) VALUES (j.id, NULL, 'new', 'Booked online by the customer from a marketing email');
  EXCEPTION WHEN others THEN NULL; END;
  BEGIN
    INSERT INTO notes (entity_type, entity_id, body, source) VALUES ('job', j.id, 'Booked online by the customer (marketing email link). No tech yet: assign one on the Dispatch board.'
      || CASE WHEN nullif(btrim(p_note), '') IS NOT NULL THEN E'\nThe customer wrote: ' || btrim(left(p_note, 1000)) ELSE '' END, 'web');
  EXCEPTION WHEN others THEN NULL; END;
  IF p_dry THEN RAISE EXCEPTION 'DRYRUN_OK job % visit %', j.id, v_visit; END IF;
  RETURN jsonb_build_object('ok', true, 'job_number', j.job_number, 'booked', jsonb_build_object('day', p_day, 'start', p_start, 'end', v_end));
END $function$;

-- Marketing page: the settings
CREATE OR REPLACE FUNCTION public.online_booking_get() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE (SELECT to_jsonb(o) || jsonb_build_object(
    'booked', (SELECT count(*) FROM online_bookings), 'upcoming', (SELECT count(*) FROM online_bookings b WHERE b.day >= current_date)) FROM online_booking o WHERE id = 1) END $f$;
CREATE OR REPLACE FUNCTION public.online_booking_set(p jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (public.current_staff_role() IN ('owner', 'admin') OR public.has_permission('staff.manage')) THEN RAISE EXCEPTION 'Only an owner can change online booking'; END IF;
  UPDATE online_booking SET phone = nullif(btrim(p ->> 'phone'), ''),
    start_days = least(greatest(coalesce((p ->> 'start_days')::int, 14), 1), 180), end_days = least(greatest(coalesce((p ->> 'end_days')::int, 60), 7), 365),
    job_type_id = nullif(p ->> 'job_type_id', '')::bigint, max_offers = least(greatest(coalesce((p ->> 'max_offers')::int, 12), 1), 40),
    set_by = auth.jwt() ->> 'email', set_at = now() WHERE id = 1;
  UPDATE online_booking SET end_days = start_days + 7 WHERE id = 1 AND end_days <= start_days;
END $function$;

REVOKE EXECUTE ON FUNCTION public._ob_type(bigint), public._ob_slots(text, date, date, numeric, numeric) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.public_book_info(text, bigint), public.public_book(text, bigint, date, text, text, boolean), public.online_booking_get(), public.online_booking_set(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.public_book_info(text, bigint), public.public_book(text, bigint, date, text, text, boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.online_booking_get(), public.online_booking_set(jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';

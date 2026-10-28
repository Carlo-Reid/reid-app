-- A practice customer for each sales person: only they can find it, booking a visit for it never goes on the board
-- (it's kept as a practice booking), and its proposals can't be sold or counted anywhere.
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS practice_user_id bigint;
CREATE UNIQUE INDEX IF NOT EXISTS customers_practice_user ON public.customers (practice_user_id) WHERE practice_user_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.practice_bookings (
  id bigserial PRIMARY KEY, user_id bigint NOT NULL, job_id bigint NOT NULL, day date, start_at timestamptz, end_at timestamptz,
  summary text, note text, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS practice_bookings_user ON public.practice_bookings (user_id, day);
ALTER TABLE public.practice_bookings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.practice_bookings FROM PUBLIC, anon, authenticated;

-- someone else's practice customer (hidden from you)
CREATE OR REPLACE FUNCTION public._practice_hidden(p_customer bigint) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT EXISTS (SELECT 1 FROM customers c WHERE c.id = p_customer AND c.practice_user_id IS NOT NULL AND c.practice_user_id IS DISTINCT FROM public.current_app_user_id())
$function$;
CREATE OR REPLACE FUNCTION public._is_practice(p_customer bigint) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT EXISTS (SELECT 1 FROM customers c WHERE c.id = p_customer AND c.practice_user_id IS NOT NULL)
$function$;

-- my practice customer: made the first time it's asked for
CREATE OR REPLACE FUNCTION public.my_practice_customer() RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_me bigint := public.current_app_user_id(); v_id bigint; v_name text; c customers;
BEGIN
  IF public.current_staff_role() IS NULL OR v_me IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT id INTO v_id FROM customers WHERE practice_user_id = v_me;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  v_name := coalesce(nullif(split_part(btrim(public._emp_name(public._my_employee())), ' ', 1), ''), split_part((SELECT login_email FROM app_users WHERE id = v_me), '@', 1), 'My');
  INSERT INTO customers (customer_number, customer_type, display_name, status, became_customer_at, lead_source, do_not_contact, marketing_opt_in, practice_user_id, notes)
  VALUES ('practice', 'residential', 'Practice Customer (' || v_name || ')', 'active', now(), 'Practice', true, false, v_me, 'Practice customer: only you can see it. Nothing done here is real.')
  RETURNING * INTO c;
  UPDATE customers SET customer_number = 'P' || c.id WHERE id = c.id;
  INSERT INTO locations (customer_id, street, city, province, postal_code, access_notes)
  VALUES (c.id, '123 Practice Street', 'Ottawa', 'ON', 'K2J 0A1', 'Practice address: nobody lives here');
  INSERT INTO customer_contacts (customer_id, kind, value, is_primary) VALUES (c.id, 'phone', '613-555-0100', true);
  RETURN c.id;
END $function$;

-- a booking for a practice customer stays a practice booking (never on the board or anyone's schedule)
SELECT public._patch_fn('book_call', '
  INSERT INTO visits (job_id, visit_number, visit_purpose', '
  IF public._is_practice(j.customer_id) THEN   -- practice-booking
    INSERT INTO practice_bookings (user_id, job_id, day, start_at, end_at, summary, note) VALUES (v_me, j.id, v_date, v_start, v_end, nullif(btrim(p ->> ''summary''), ''''), v_note);
    RETURN jsonb_build_object(''job_id'', j.id, ''visit_id'', NULL, ''job_number'', j.job_number, ''practice'', true);
  END IF;
  INSERT INTO visits (job_id, visit_number, visit_purpose');

-- proposals for a practice customer can't be sold
SELECT public._patch_fn('est_close', 'IF e.status = ''accepted'' THEN RAISE EXCEPTION ''This deal is already closed''; END IF;',
  'IF e.status = ''accepted'' THEN RAISE EXCEPTION ''This deal is already closed''; END IF;
  IF public._is_practice(e.customer_id) THEN RAISE EXCEPTION ''This is your practice customer, so nothing is really sold. In real life the deal would now be closed.''; END IF;');
SELECT public._patch_fn('est_sold_invoice', 'IF e.id IS NULL THEN RAISE EXCEPTION ''That estimate no longer exists''; END IF;',
  'IF e.id IS NULL THEN RAISE EXCEPTION ''That estimate no longer exists''; END IF;
  IF public._is_practice(e.customer_id) THEN RAISE EXCEPTION ''This is a practice customer, so no invoice is made.''; END IF;');

-- nobody else finds it
SELECT public._patch_fn('search_customers', 'AND (length(v_any) < 2 OR c.id IN (SELECT customer_id FROM any_ids))',
  'AND (length(v_any) < 2 OR c.id IN (SELECT customer_id FROM any_ids))
      AND (c.practice_user_id IS NULL OR c.practice_user_id = public.current_app_user_id())');
SELECT public._patch_fn('customer_find', 'FROM customers c WHERE c.merged_into_id IS NULL),',
  'FROM customers c WHERE c.merged_into_id IS NULL AND (c.practice_user_id IS NULL OR c.practice_user_id = public.current_app_user_id())),');
SELECT public._patch_fn('global_search', 'WHERE (SELECT public.current_staff_role()) IS NOT NULL',
  'WHERE (SELECT public.current_staff_role()) IS NOT NULL AND (s.customer_id IS NULL OR NOT public._practice_hidden(s.customer_id))');
SELECT public._patch_fn('_sales_list', 'AND jb.sales_cancelled_at IS NULL   -- cancelled from the Sales page',
  'AND jb.sales_cancelled_at IS NULL AND NOT public._practice_hidden(jb.customer_id)   -- cancelled from the Sales page');

-- My booked calls: the real ones plus my practice bookings
CREATE OR REPLACE FUNCTION public.my_booked_calls(p_employee bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_emp bigint := CASE WHEN p_employee IS NOT NULL AND (public.current_staff_role() = 'owner' OR public.has_permission('calls.dispatch')) THEN p_employee ELSE public._my_employee() END;
        v_today date := (now() AT TIME ZONE 'America/Toronto')::date; v_me bigint := public.current_app_user_id();
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x->>'day', x->>'from' NULLS LAST) FROM (
    SELECT jsonb_build_object('visit', v.id, 'job', j.id, 'job_number', j.job_number, 'day', v.scheduled_date, 'from', v.arrival_start, 'to', v.arrival_end,
      'status', v.status, 'kind', j.sales_kind, 'on_site', j.sales_on_site_at, 'summary', j.summary,
      'customer_id', j.customer_id, 'customer', coalesce(c.display_name, c.company_name), 'street', l.street, 'unit', l.unit, 'city', l.city, 'access', l.access_notes,
      'est_id', (SELECT max(e.id) FROM estimates e WHERE e.job_id = j.id AND e.cancelled_at IS NULL),
      'est_number', (SELECT e.estimate_number FROM estimates e WHERE e.id = (SELECT max(e2.id) FROM estimates e2 WHERE e2.job_id = j.id AND e2.cancelled_at IS NULL))) x
    FROM visits v JOIN visit_assignments va ON va.visit_id = v.id AND va.employee_id = v_emp
    JOIN jobs j ON j.id = v.job_id LEFT JOIN customers c ON c.id = j.customer_id LEFT JOIN locations l ON l.id = j.location_id
    WHERE v_emp IS NOT NULL AND v.scheduled_date BETWEEN v_today - 3 AND v_today + 60 AND v.status NOT IN ('cancelled', 'completed')
      AND j.sales_cancelled_at IS NULL AND j.status IS DISTINCT FROM 'cancelled'
    UNION ALL
    SELECT jsonb_build_object('practice_id', b.id, 'practice', true, 'job', j.id, 'job_number', j.job_number, 'day', b.day, 'from', b.start_at, 'to', b.end_at,
      'kind', j.sales_kind, 'on_site', j.sales_on_site_at, 'summary', coalesce(b.summary, j.summary),
      'customer_id', j.customer_id, 'customer', c.display_name, 'street', l.street, 'unit', l.unit, 'city', l.city, 'access', b.note,
      'est_id', (SELECT max(e.id) FROM estimates e WHERE e.job_id = j.id AND e.cancelled_at IS NULL),
      'est_number', (SELECT e.estimate_number FROM estimates e WHERE e.id = (SELECT max(e2.id) FROM estimates e2 WHERE e2.job_id = j.id AND e2.cancelled_at IS NULL)))
    FROM practice_bookings b JOIN jobs j ON j.id = b.job_id LEFT JOIN customers c ON c.id = j.customer_id LEFT JOIN locations l ON l.id = j.location_id
    WHERE p_employee IS NULL AND b.user_id = v_me AND (b.day IS NULL OR b.day BETWEEN v_today - 3 AND v_today + 60)) s), '[]'::jsonb);
END $function$;

CREATE OR REPLACE FUNCTION public.practice_booking_move(p_id bigint, p_date date, p_start text, p_end text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  UPDATE practice_bookings SET day = p_date, start_at = public._local_ts(p_date, p_start), end_at = public._local_ts(p_date, p_end)
  WHERE id = p_id AND user_id = public.current_app_user_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'That practice booking is gone'; END IF;
END $function$;
CREATE OR REPLACE FUNCTION public.practice_booking_del(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN DELETE FROM practice_bookings WHERE id = p_id AND user_id = public.current_app_user_id(); END $function$;

REVOKE EXECUTE ON FUNCTION public._practice_hidden(bigint), public._is_practice(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.my_practice_customer(), public.my_booked_calls(bigint), public.practice_booking_move(bigint, date, text, text), public.practice_booking_del(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_practice_customer(), public.my_booked_calls(bigint), public.practice_booking_move(bigint, date, text, text), public.practice_booking_del(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

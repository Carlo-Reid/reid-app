-- "Book today with a deposit and we'll double your rebate": the sales person holds an install day (in the week a week out)
-- where 2 or more installers are free. The hold shows on the dispatch board until the office confirms or releases it.
CREATE TABLE IF NOT EXISTS public.install_holds (
  id bigserial PRIMARY KEY, estimate_id bigint NOT NULL, job_id bigint, customer_id bigint, day date NOT NULL,
  status text NOT NULL DEFAULT 'held' CHECK (status IN ('held', 'confirmed', 'released')),
  held_by bigint, created_at timestamptz NOT NULL DEFAULT now(), decided_by bigint, decided_at timestamptz, note text);
CREATE INDEX IF NOT EXISTS install_holds_day ON public.install_holds (day) WHERE status <> 'released';
CREATE UNIQUE INDEX IF NOT EXISTS install_holds_est ON public.install_holds (estimate_id) WHERE status <> 'released';
ALTER TABLE public.install_holds ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.install_holds FROM PUBLIC, anon, authenticated;

-- the week (Mon-Fri) a week from today
CREATE OR REPLACE FUNCTION public._hold_week() RETURNS date LANGUAGE sql STABLE AS $function$
  SELECT date_trunc('week', ((now() AT TIME ZONE 'America/Toronto')::date + 7)::timestamp)::date
$function$;

-- installers free each day: no call that day, not marked busy, less 2 for each install already held that day
CREATE OR REPLACE FUNCTION public.install_hold_days(p_estimate bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_mon date := public._hold_week();
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('from', v_mon, 'to', v_mon + 4,
    'mine', (SELECT jsonb_build_object('id', h.id, 'day', h.day, 'status', h.status) FROM install_holds h WHERE h.estimate_id = p_estimate AND h.status <> 'released'),
    'days', (SELECT jsonb_agg(jsonb_build_object('day', d, 'free', greatest(f.n - 2 * hd.n, 0), 'names', f.names) ORDER BY d)
      FROM generate_series(v_mon, v_mon + 4, interval '1 day') g(d0), LATERAL (SELECT g.d0::date AS d) dd,
      LATERAL (SELECT count(*) AS n, string_agg(btrim(e.first_name), ', ' ORDER BY e.first_name) AS names FROM employees e
               WHERE e.active AND e.tech_kind = 'installs' AND coalesce(e.merged_into, 0) = 0
                 AND NOT EXISTS (SELECT 1 FROM visits v JOIN visit_assignments va ON va.visit_id = v.id
                                 WHERE va.employee_id = e.id AND v.scheduled_date = dd.d AND v.status NOT IN ('cancelled'))
                 AND NOT EXISTS (SELECT 1 FROM staff_blocks b WHERE b.employee_id = e.id AND b.day = dd.d)) f,
      LATERAL (SELECT count(*) AS n FROM install_holds h WHERE h.day = dd.d AND h.status = 'held' AND h.estimate_id <> p_estimate
               AND NOT public._is_practice(h.customer_id)) hd));
END $function$;

-- hold a day for this proposal (one per proposal); a null day lets it go
CREATE OR REPLACE FUNCTION public.install_hold_set(p_estimate bigint, p_day date) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE e estimates; v_mon date := public._hold_week(); v jsonb; v_free int;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT * INTO e FROM estimates WHERE id = p_estimate; IF e.id IS NULL THEN RAISE EXCEPTION 'That proposal no longer exists'; END IF;
  IF p_day IS NULL THEN
    UPDATE install_holds SET status = 'released', decided_by = public.current_app_user_id(), decided_at = now(), note = 'Taken off by the sales person'
    WHERE estimate_id = p_estimate AND status = 'held';
    RETURN NULL; END IF;
  IF p_day < v_mon OR p_day > v_mon + 4 THEN RAISE EXCEPTION 'Pick one of the days shown'; END IF;
  SELECT (x ->> 'free')::int INTO v_free FROM jsonb_array_elements(public.install_hold_days(p_estimate) -> 'days') x WHERE (x ->> 'day')::date = p_day;
  IF coalesce(v_free, 0) < 2 THEN RAISE EXCEPTION 'That day just filled up. Pick another day.'; END IF;
  UPDATE install_holds SET day = p_day, created_at = now(), held_by = public.current_app_user_id() WHERE estimate_id = p_estimate AND status = 'held';
  IF NOT FOUND THEN
    IF EXISTS (SELECT 1 FROM install_holds WHERE estimate_id = p_estimate AND status = 'confirmed') THEN RAISE EXCEPTION 'The office already confirmed the install day'; END IF;
    INSERT INTO install_holds (estimate_id, job_id, customer_id, day, held_by) VALUES (p_estimate, e.job_id, e.customer_id, p_day, public.current_app_user_id());
  END IF;
  RETURN jsonb_build_object('day', p_day);
END $function$;

-- for the board: holds in a date range (someone's practice customer never shows)
CREATE OR REPLACE FUNCTION public.install_holds_list(p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', h.id, 'day', h.day, 'status', h.status, 'estimate_id', h.estimate_id, 'estimate_number', e.estimate_number,
      'job_id', h.job_id, 'customer_id', h.customer_id, 'customer', c.display_name, 'city', l.city,
      'by', coalesce(public._emp_name(u.employee_id), u.login_email), 'at', h.created_at,
      'can_decide', public.has_permission('calls.dispatch') OR public.current_staff_role() = 'owner') ORDER BY h.day, h.id)
    FROM install_holds h LEFT JOIN estimates e ON e.id = h.estimate_id LEFT JOIN customers c ON c.id = h.customer_id
    LEFT JOIN locations l ON l.id = e.location_id LEFT JOIN app_users u ON u.id = h.held_by
    WHERE h.status <> 'released' AND h.day BETWEEN p_from AND p_to AND NOT public._practice_hidden(h.customer_id)), '[]'::jsonb);
END $function$;

CREATE OR REPLACE FUNCTION public.install_hold_decide(p_id bigint, p_status text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (public.has_permission('calls.dispatch') OR public.current_staff_role() = 'owner') THEN RAISE EXCEPTION 'Only the office can do this'; END IF;
  IF p_status NOT IN ('confirmed', 'released', 'held') THEN RAISE EXCEPTION 'Unknown choice'; END IF;
  UPDATE install_holds SET status = p_status, decided_by = public.current_app_user_id(), decided_at = now() WHERE id = p_id;
END $function$;

REVOKE EXECUTE ON FUNCTION public.install_hold_days(bigint), public.install_hold_set(bigint, date), public.install_holds_list(date, date), public.install_hold_decide(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.install_hold_days(bigint), public.install_hold_set(bigint, date), public.install_holds_list(date, date), public.install_hold_decide(bigint, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

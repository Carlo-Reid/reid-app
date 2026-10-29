-- "Pick a day and see if your rebate is available": any weekday in the 30 days from a week out, same rule (2+ installers free)
CREATE OR REPLACE FUNCTION public._hold_free(p_estimate bigint, p_from date, p_to date) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT coalesce(jsonb_agg(jsonb_build_object('day', dd.d, 'free', greatest(f.n - 2 * hd.n, 0), 'names', f.names) ORDER BY dd.d), '[]'::jsonb)
  FROM generate_series(p_from, p_to, interval '1 day') g(d0), LATERAL (SELECT g.d0::date AS d) dd,
  LATERAL (SELECT count(*) AS n, string_agg(btrim(e.first_name), ', ' ORDER BY e.first_name) AS names FROM employees e
           WHERE e.active AND e.tech_kind = 'installs' AND coalesce(e.merged_into, 0) = 0
             AND NOT EXISTS (SELECT 1 FROM visits v JOIN visit_assignments va ON va.visit_id = v.id
                             WHERE va.employee_id = e.id AND v.scheduled_date = dd.d AND v.status NOT IN ('cancelled'))
             AND NOT EXISTS (SELECT 1 FROM staff_blocks b WHERE b.employee_id = e.id AND b.day = dd.d)) f,
  LATERAL (SELECT count(*) AS n FROM install_holds h WHERE h.day = dd.d AND h.status = 'held' AND h.estimate_id <> p_estimate
           AND NOT public._is_practice(h.customer_id)) hd
  WHERE extract(isodow FROM dd.d) < 6
$function$;
REVOKE EXECUTE ON FUNCTION public._hold_free(bigint, date, date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.install_hold_cal(p_estimate bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_mon date := public._hold_week();
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('from', v_mon, 'to', v_mon + 29, 'days', public._hold_free(p_estimate, v_mon, v_mon + 29));
END $function$;
REVOKE EXECUTE ON FUNCTION public.install_hold_cal(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.install_hold_cal(bigint) TO authenticated;

SELECT public._patch_fn('install_hold_set', $o$IF p_day < v_mon OR p_day > v_mon + 4 THEN RAISE EXCEPTION 'Pick one of the days shown'; END IF;
  SELECT (x ->> 'free')::int INTO v_free FROM jsonb_array_elements(public.install_hold_days(p_estimate) -> 'days') x WHERE (x ->> 'day')::date = p_day;$o$,
  $n$IF p_day < v_mon OR p_day > v_mon + 29 THEN RAISE EXCEPTION 'Pick one of the days shown'; END IF;
  SELECT (x ->> 'free')::int INTO v_free FROM jsonb_array_elements(public._hold_free(p_estimate, p_day, p_day)) x WHERE (x ->> 'day')::date = p_day;$n$);
NOTIFY pgrst, 'reload schema';

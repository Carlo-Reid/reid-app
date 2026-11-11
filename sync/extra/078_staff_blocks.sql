-- Personal appointments: an employee marks themselves busy (a time or the whole day). They show on the dispatch board on that
-- person's line like a call, on the week / month board, and on a sales person's calendar.
CREATE TABLE IF NOT EXISTS public.staff_blocks (
  id bigserial PRIMARY KEY,
  employee_id bigint NOT NULL,
  day date NOT NULL,
  start_time time,                 -- null = all day
  end_time time,
  title text NOT NULL DEFAULT 'Busy',
  created_by bigint,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS staff_blocks_day ON public.staff_blocks (day, employee_id);
ALTER TABLE public.staff_blocks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.staff_blocks FROM PUBLIC, anon, authenticated;

-- everyone's (for the board), or one person's
-- George, Nov 10, 2026: "you are not adding the events that are Grey": the events on a tech's ServiceTitan schedule (st_nonjob_appts: "off sick today",
-- a meeting, a hold) come back here too, as busy times ('st' true, can not be deleted here), so they show on the dispatch board, the week and month
-- views and when picking a tech. Only active ones; the nightly 3:30 a.m. "calls past this are for the next day" marker is left out.
CREATE OR REPLACE FUNCTION public.staff_blocks_list(p_from date, p_to date, p_employee bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_st boolean := to_regclass('public.st_nonjob_appts') IS NOT NULL; v_ev jsonb := '[]'::jsonb;
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN '[]'::jsonb; END IF;
  IF v_st THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', -x.id, 'employee_id', x.emp, 'name', public._emp_name(x.emp), 'day', x.d,
        'start', CASE WHEN x.all_day THEN NULL ELSE to_char(x.s, 'HH24:MI') END,
        'end', CASE WHEN x.all_day THEN NULL WHEN (x.s + make_interval(mins => greatest(x.mins, 15)))::date > x.d THEN '23:59' ELSE to_char(x.s + make_interval(mins => greatest(x.mins, 15)), 'HH24:MI') END,
        'title', x.title, 'mine', x.emp = public._my_employee(), 'can_delete', false, 'st', true) ORDER BY x.d, x.s), '[]'::jsonb) INTO v_ev
    FROM (SELECT n.id, coalesce(e.merged_into, e.id) AS emp, (n.starts_at AT TIME ZONE 'America/Toronto') AS s, (n.starts_at AT TIME ZONE 'America/Toronto')::date AS d,
                 coalesce(n.duration_min, 60) AS mins, coalesce(n.all_day, false) AS all_day, coalesce(nullif(btrim(n.name), ''), 'Busy') AS title
          FROM st_nonjob_appts n JOIN employees e ON e.st_id = n.technician_id
          WHERE n.active AND n.starts_at >= (p_from::timestamp AT TIME ZONE 'America/Toronto') AND n.starts_at < ((p_to + 1)::timestamp AT TIME ZONE 'America/Toronto')) x
    WHERE (p_employee IS NULL OR x.emp = p_employee)
      AND NOT (NOT x.all_day AND (x.s + make_interval(mins => x.mins))::time <= time '06:00' AND (x.s + make_interval(mins => x.mins))::date = x.d);
  END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', b.id, 'employee_id', b.employee_id, 'name', public._emp_name(b.employee_id), 'day', b.day,
      'start', to_char(b.start_time, 'HH24:MI'), 'end', to_char(b.end_time, 'HH24:MI'), 'title', b.title,
      'mine', b.employee_id = public._my_employee(), 'can_delete', b.employee_id = public._my_employee() OR b.created_by = public.current_app_user_id() OR public.has_permission('calls.dispatch') OR public.current_staff_role() = 'owner')
      ORDER BY b.day, b.start_time NULLS FIRST, b.id)
    FROM staff_blocks b WHERE b.day BETWEEN p_from AND p_to AND (p_employee IS NULL OR b.employee_id = p_employee)), '[]'::jsonb) || v_ev;
END $function$;

CREATE OR REPLACE FUNCTION public.staff_block_add(p_day date, p_start time, p_end time, p_title text) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_emp bigint := public._my_employee(); v bigint;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  IF v_emp IS NULL THEN RAISE EXCEPTION 'Your log-in isn''t linked to a name on the schedule yet. Ask the office to set "On the schedule as" on the Staff page.'; END IF;
  IF p_day IS NULL THEN RAISE EXCEPTION 'Pick the day'; END IF;
  IF p_start IS NOT NULL AND p_end IS NOT NULL AND p_end <= p_start THEN RAISE EXCEPTION 'The end time has to be after the start time'; END IF;
  INSERT INTO staff_blocks (employee_id, day, start_time, end_time, title, created_by)
  VALUES (v_emp, p_day, p_start, CASE WHEN p_start IS NULL THEN NULL ELSE coalesce(p_end, p_start + interval '1 hour') END, coalesce(nullif(left(btrim(p_title), 200), ''), 'Busy'), public.current_app_user_id())
  RETURNING id INTO v;
  RETURN v;
END $function$;

CREATE OR REPLACE FUNCTION public.staff_block_del(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM staff_blocks b WHERE b.id = p_id AND (b.employee_id = public._my_employee() OR b.created_by = public.current_app_user_id()
                 OR public.has_permission('calls.dispatch') OR public.current_staff_role() = 'owner')) THEN
    RAISE EXCEPTION 'You can only take off your own'; END IF;
  DELETE FROM staff_blocks WHERE id = p_id;
END $function$;
REVOKE EXECUTE ON FUNCTION public.staff_blocks_list(date, date, bigint), public.staff_block_add(date, time, time, text), public.staff_block_del(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_blocks_list(date, date, bigint), public.staff_block_add(date, time, time, text), public.staff_block_del(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

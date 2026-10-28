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
CREATE OR REPLACE FUNCTION public.staff_blocks_list(p_from date, p_to date, p_employee bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', b.id, 'employee_id', b.employee_id, 'name', public._emp_name(b.employee_id), 'day', b.day,
      'start', to_char(b.start_time, 'HH24:MI'), 'end', to_char(b.end_time, 'HH24:MI'), 'title', b.title,
      'mine', b.employee_id = public._my_employee(), 'can_delete', b.employee_id = public._my_employee() OR b.created_by = public.current_app_user_id() OR public.has_permission('calls.dispatch') OR public.current_staff_role() = 'owner')
      ORDER BY b.day, b.start_time NULLS FIRST, b.id)
    FROM staff_blocks b WHERE b.day BETWEEN p_from AND p_to AND (p_employee IS NULL OR b.employee_id = p_employee)), '[]'::jsonb);
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

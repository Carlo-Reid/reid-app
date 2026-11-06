-- Office staff time: expected hours per weekday (set by an owner), and each work day's time in / time out.
-- The work day turns over at 2 am (Ottawa time). Time in: "Let's start the day" (or signing in in the morning).
-- Time out: the "Done work" button; if they forget, their last typing / click / scroll, and they're asked to verify it.
-- Pay counts only from 15 minutes before the expected start to 15 minutes after the expected end (worked out on the Payroll page).
CREATE TABLE IF NOT EXISTS public.office_schedule (
  app_user_id bigint NOT NULL, weekday smallint NOT NULL CHECK (weekday BETWEEN 1 AND 7),   -- 1 = Monday … 7 = Sunday
  starts time NOT NULL, ends time NOT NULL, PRIMARY KEY (app_user_id, weekday));
CREATE TABLE IF NOT EXISTS public.office_shifts (
  id bigserial PRIMARY KEY, app_user_id bigint NOT NULL, day date NOT NULL,
  time_in timestamptz NOT NULL, time_out timestamptz, out_source text,        -- 'button', 'auto' (last activity), 'verified', 'edited' (owner)
  last_activity timestamptz, verified boolean NOT NULL DEFAULT true, edited_by text, edited_at timestamptz,
  UNIQUE (app_user_id, day));
ALTER TABLE public.office_schedule ENABLE ROW LEVEL SECURITY; ALTER TABLE public.office_shifts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.office_schedule, public.office_shifts FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._office_today() RETURNS date LANGUAGE sql STABLE AS $f$ SELECT ((now() AT TIME ZONE 'America/Toronto') - interval '2 hours')::date $f$;
CREATE OR REPLACE FUNCTION public._is_office(p_user bigint) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT EXISTS (SELECT 1 FROM app_users WHERE id = p_user AND active AND role IN ('office', 'admin', 'accounting', 'dispatcher', 'warehouse')) $f$;
-- days they forgot to press Done work: their last activity becomes the time out, and they're asked to verify it
CREATE OR REPLACE FUNCTION public._office_autoclose(p_user bigint) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE office_shifts SET time_out = greatest(coalesce(last_activity, time_in), time_in), out_source = 'auto', verified = false
   WHERE app_user_id = p_user AND time_out IS NULL AND day < public._office_today() $f$;

-- the signed-in person: are they office staff, today's day, and any time outs to verify
CREATE OR REPLACE FUNCTION public.office_day_status() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE u bigint := public.current_app_user_id(); r office_shifts;
BEGIN
  IF u IS NULL OR NOT public._is_office(u) THEN RETURN jsonb_build_object('office', false); END IF;
  PERFORM public._office_autoclose(u);
  SELECT * INTO r FROM office_shifts WHERE app_user_id = u AND day = public._office_today();
  RETURN jsonb_build_object('office', true, 'day', public._office_today(),
    'today', CASE WHEN r.id IS NULL THEN NULL ELSE jsonb_build_object('id', r.id, 'time_in', r.time_in, 'time_out', r.time_out) END,
    'verify', coalesce((SELECT jsonb_agg(jsonb_build_object('id', id, 'day', day, 'time_in', time_in, 'time_out', time_out) ORDER BY day)
                        FROM office_shifts WHERE app_user_id = u AND NOT verified), '[]'::jsonb));
END $function$;

CREATE OR REPLACE FUNCTION public.office_day_start() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE u bigint := public.current_app_user_id();
BEGIN
  IF u IS NULL OR NOT public._is_office(u) THEN RAISE EXCEPTION 'Only office staff use the work day'; END IF;
  INSERT INTO office_shifts (app_user_id, day, time_in, last_activity) VALUES (u, public._office_today(), now(), now()) ON CONFLICT (app_user_id, day) DO NOTHING;
  RETURN public.office_day_status();
END $function$;

CREATE OR REPLACE FUNCTION public.office_ping() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE office_shifts SET last_activity = now() WHERE app_user_id = public.current_app_user_id() AND day = public._office_today() AND time_out IS NULL $f$;

-- Done work (p_done true), or "not done yet" (false: back to work, the time out is cleared)
CREATE OR REPLACE FUNCTION public.office_day_done(p_done boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE u bigint := public.current_app_user_id();
BEGIN
  UPDATE office_shifts SET time_out = CASE WHEN p_done THEN now() END, out_source = CASE WHEN p_done THEN 'button' END, last_activity = now()
   WHERE app_user_id = u AND day = public._office_today();
  RETURN public.office_day_status();
END $function$;

-- they confirm (or correct) a time out the app filled in
CREATE OR REPLACE FUNCTION public.office_verify(p_id bigint, p_time_out timestamptz) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE r office_shifts;
BEGIN
  SELECT * INTO r FROM office_shifts WHERE id = p_id AND app_user_id = public.current_app_user_id(); IF NOT FOUND THEN RAISE EXCEPTION 'Not found'; END IF;
  IF p_time_out <= r.time_in THEN RAISE EXCEPTION 'The time out has to be after the time in'; END IF;
  UPDATE office_shifts SET time_out = p_time_out, out_source = 'verified', verified = true WHERE id = p_id;
  RETURN public.office_day_status();
END $function$;

-- Payroll page: one office person's expected hours and days in a period (owners, or the person themselves)
CREATE OR REPLACE FUNCTION public.office_period(p_user bigint, p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._payroll_can(p_user) THEN RETURN NULL; END IF;
  PERFORM public._office_autoclose(p_user);
  RETURN jsonb_build_object('office', public._is_office(p_user), 'name', public._staff_name(p_user),
    'schedule', coalesce((SELECT jsonb_agg(jsonb_build_object('weekday', weekday, 'starts', to_char(starts, 'HH24:MI'), 'ends', to_char(ends, 'HH24:MI')) ORDER BY weekday)
                          FROM office_schedule WHERE app_user_id = p_user), '[]'::jsonb),
    'days', coalesce((SELECT jsonb_agg(jsonb_build_object('id', id, 'day', day, 'time_in', time_in, 'time_out', time_out, 'source', out_source,
                          'verified', verified, 'last_activity', last_activity, 'edited_by', edited_by) ORDER BY day)
                      FROM office_shifts WHERE app_user_id = p_user AND day BETWEEN p_from AND p_to), '[]'::jsonb));
END $function$;

-- owner: set the expected hours (a list of {weekday, starts, ends}; days left out are days off)
CREATE OR REPLACE FUNCTION public.office_schedule_set(p_user bigint, p_days jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only owners set the expected hours'; END IF;
  DELETE FROM office_schedule WHERE app_user_id = p_user;
  INSERT INTO office_schedule (app_user_id, weekday, starts, ends)
  SELECT p_user, (x ->> 'weekday')::smallint, (x ->> 'starts')::time, (x ->> 'ends')::time FROM jsonb_array_elements(coalesce(p_days, '[]'::jsonb)) x
   WHERE coalesce(x ->> 'starts', '') <> '' AND coalesce(x ->> 'ends', '') <> '' AND (x ->> 'ends')::time > (x ->> 'starts')::time;
END $function$;

-- owner: change a day's time in / out (or add a missing day)
CREATE OR REPLACE FUNCTION public.office_shift_set(p_user bigint, p_day date, p_in timestamptz, p_out timestamptz) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only owners change the times'; END IF;
  IF p_in IS NULL THEN DELETE FROM office_shifts WHERE app_user_id = p_user AND day = p_day; RETURN; END IF;
  IF p_out IS NOT NULL AND p_out <= p_in THEN RAISE EXCEPTION 'The time out has to be after the time in'; END IF;
  INSERT INTO office_shifts (app_user_id, day, time_in, time_out, out_source, verified, edited_by, edited_at)
  VALUES (p_user, p_day, p_in, p_out, CASE WHEN p_out IS NOT NULL THEN 'edited' END, true, auth.jwt() ->> 'email', now())
  ON CONFLICT (app_user_id, day) DO UPDATE SET time_in = EXCLUDED.time_in, time_out = EXCLUDED.time_out, out_source = EXCLUDED.out_source,
    verified = true, edited_by = EXCLUDED.edited_by, edited_at = now();
END $function$;

REVOKE EXECUTE ON FUNCTION public._is_office(bigint), public._office_autoclose(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.office_day_status(), public.office_day_start(), public.office_ping(), public.office_day_done(boolean), public.office_verify(bigint, timestamptz),
  public.office_period(bigint, date, date), public.office_schedule_set(bigint, jsonb), public.office_shift_set(bigint, date, timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.office_day_status(), public.office_day_start(), public.office_ping(), public.office_day_done(boolean), public.office_verify(bigint, timestamptz),
  public.office_period(bigint, date, date), public.office_schedule_set(bigint, jsonb), public.office_shift_set(bigint, date, timestamptz, timestamptz) TO authenticated;
NOTIFY pgrst, 'reload schema';

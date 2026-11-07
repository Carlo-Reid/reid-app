-- When each person started working with us (Staff page), for the HSG Pro messages ("You've been with us for 6 years…").
-- Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.staff_started (app_user_id bigint PRIMARY KEY, started_on date NOT NULL, set_by text, set_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.staff_started ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.staff_started FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.staff_started_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.has_permission('staff.manage') OR public.current_staff_role() = 'owner'
    THEN coalesce((SELECT jsonb_agg(jsonb_build_object('user', app_user_id, 'started', started_on)) FROM staff_started), '[]'::jsonb) ELSE '[]'::jsonb END $f$;

CREATE OR REPLACE FUNCTION public.staff_started_set(p_user bigint, p_date date) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (public.has_permission('staff.manage') OR public.current_staff_role() = 'owner') THEN RAISE EXCEPTION 'You need "Manage staff" to change this'; END IF;
  IF p_date IS NULL THEN DELETE FROM staff_started WHERE app_user_id = p_user; RETURN; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'The start date can''t be in the future'; END IF;
  INSERT INTO staff_started (app_user_id, started_on, set_by) VALUES (p_user, p_date, auth.jwt() ->> 'email')
  ON CONFLICT (app_user_id) DO UPDATE SET started_on = EXCLUDED.started_on, set_by = EXCLUDED.set_by, set_at = now();
END $function$;

-- the signed-in person's own start date and first name
CREATE OR REPLACE FUNCTION public.my_started() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT jsonb_build_object('started', (SELECT started_on FROM staff_started WHERE app_user_id = public.current_app_user_id()),
    'first', (SELECT coalesce(nullif(e.first_name, ''), initcap(split_part(u.login_email::text, '@', 1))) FROM app_users u LEFT JOIN employees e ON e.id = u.employee_id WHERE u.id = public.current_app_user_id())) $f$;

REVOKE EXECUTE ON FUNCTION public.staff_started_list(), public.staff_started_set(bigint, date), public.my_started() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_started_list(), public.staff_started_set(bigint, date), public.my_started() TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Carlo, Nov 17, 2026: "if you pick up your truck from office in the morning you get paid 30 minutes before any call you do… a spot in the staff page
-- that lets me check a box if the tech takes his truck home or does not". One row for each person who picks his truck up at the office in the morning.
-- No row = he takes his truck home (no extra time). The payroll page reads it and starts the day 30 minutes before the first On my way.
CREATE TABLE IF NOT EXISTS public.staff_truck_office (app_user_id bigint PRIMARY KEY, set_by text, set_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.staff_truck_office ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.staff_truck_office FROM PUBLIC, anon, authenticated;

-- Staff page: everyone who picks up at the office
CREATE OR REPLACE FUNCTION public.staff_truck_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.has_permission('staff.manage') OR public.current_staff_role() = 'owner'
    THEN coalesce((SELECT jsonb_agg(app_user_id) FROM staff_truck_office), '[]'::jsonb) ELSE '[]'::jsonb END $f$;

CREATE OR REPLACE FUNCTION public.staff_truck_set(p_user bigint, p_office boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (public.has_permission('staff.manage') OR public.current_staff_role() = 'owner') THEN RAISE EXCEPTION 'You need "Manage staff" to change this'; END IF;
  IF p_user IS NULL THEN RAISE EXCEPTION 'No person picked'; END IF;
  IF coalesce(p_office, false) THEN
    INSERT INTO staff_truck_office (app_user_id, set_by) VALUES (p_user, auth.jwt() ->> 'email')
    ON CONFLICT (app_user_id) DO UPDATE SET set_by = EXCLUDED.set_by, set_at = now();
  ELSE DELETE FROM staff_truck_office WHERE app_user_id = p_user; END IF;
END $function$;

-- the payroll page: does this person pick his truck up at the office? (an owner, or the person himself)
CREATE OR REPLACE FUNCTION public.staff_truck_office_is(p_user bigint) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() = 'owner' OR p_user = public.current_app_user_id()
    THEN EXISTS (SELECT 1 FROM staff_truck_office WHERE app_user_id = p_user) ELSE false END $f$;

REVOKE EXECUTE ON FUNCTION public.staff_truck_list(), public.staff_truck_set(bigint, boolean), public.staff_truck_office_is(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_truck_list(), public.staff_truck_set(bigint, boolean), public.staff_truck_office_is(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

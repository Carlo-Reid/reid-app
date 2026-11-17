-- Where the tech was when On my way was pressed in the app (Carlo, Nov 17, 2026).
-- Every press is kept; the newest one of a call is the one shown.
CREATE TABLE IF NOT EXISTS public.on_way_places (
  id bigserial PRIMARY KEY, visit_id bigint NOT NULL REFERENCES public.visits(id) ON DELETE CASCADE,
  lat double precision NOT NULL, lng double precision NOT NULL, acc numeric, at timestamptz NOT NULL DEFAULT now(), by_user bigint, by_name text);
CREATE INDEX IF NOT EXISTS on_way_places_visit ON public.on_way_places (visit_id, at DESC);
ALTER TABLE public.on_way_places ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.on_way_places FROM PUBLIC, anon, authenticated;
-- Nov 17, 2026, 4:11 p.m.: the same table also keeps where the call was started (I'm here) and ended (Done): kind = way | start | end (316_call_place_stamps.sql)
ALTER TABLE public.on_way_places ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'way';

-- save the spot: the tech on the call, or the office / dispatch / an owner pressing it for him
CREATE OR REPLACE FUNCTION public.on_way_place_set(p_visit bigint, p_lat double precision, p_lng double precision, p_acc numeric DEFAULT NULL) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_user bigint := public.current_app_user_id(); v_role text := public.current_staff_role(); v_emp bigint; v_name text;
BEGIN
  IF v_user IS NULL OR v_role IS NULL THEN RETURN jsonb_build_object('ok', false, 'why', 'not_allowed'); END IF;
  IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN RETURN jsonb_build_object('ok', false, 'why', 'no_place'); END IF;
  IF NOT EXISTS (SELECT 1 FROM visits WHERE id = p_visit) THEN RETURN jsonb_build_object('ok', false, 'why', 'no_call'); END IF;
  SELECT u.employee_id, coalesce(nullif(trim(coalesce(e.first_name, '') || ' ' || coalesce(e.last_name, '')), ''), u.login_email)
    INTO v_emp, v_name FROM app_users u LEFT JOIN employees e ON e.id = u.employee_id WHERE u.id = v_user;
  IF v_role NOT IN ('owner', 'admin', 'office', 'dispatcher')
     AND NOT EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id = p_visit AND va.employee_id = v_emp) THEN
    RETURN jsonb_build_object('ok', false, 'why', 'not_allowed'); END IF;
  INSERT INTO on_way_places (visit_id, lat, lng, acc, by_user, by_name) VALUES (p_visit, p_lat, p_lng, p_acc, v_user, v_name);
  RETURN jsonb_build_object('ok', true);
END $f$;

-- read the newest spot of each call: owners and dispatch see all; anyone else only the ones they pressed themselves
CREATE OR REPLACE FUNCTION public.on_way_places_for(p_visits bigint[]) RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object(
      'visit_id', x.visit_id, 'lat', x.lat, 'lng', x.lng, 'acc', x.acc, 'at', x.at, 'by', x.by_name)) FROM (
    SELECT DISTINCT ON (p.visit_id) p.* FROM on_way_places p WHERE p.visit_id = ANY (p_visits) AND p.kind = 'way'
       AND (public.current_staff_role() = 'owner' OR public.has_permission('calls.dispatch') OR p.by_user = public.current_app_user_id())
     ORDER BY p.visit_id, p.at DESC, p.id DESC) x), '[]'::jsonb) END $f$;

REVOKE EXECUTE ON FUNCTION public.on_way_place_set(bigint, double precision, double precision, numeric), public.on_way_places_for(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.on_way_place_set(bigint, double precision, double precision, numeric), public.on_way_places_for(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

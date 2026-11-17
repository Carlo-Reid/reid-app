-- A location stamp on every call for its start (I'm here) and its end (Done / Needs another visit / walk completed) (Carlo, Nov 17, 2026, 4:11 p.m.).
-- Kept in on_way_places with kind = start | end (kind = way is the On my way press, 313). Every press is kept; the newest of each kind is shown.
ALTER TABLE public.on_way_places ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'way';
CREATE INDEX IF NOT EXISTS on_way_places_visit_kind ON public.on_way_places (visit_id, kind, at DESC);

-- save a stamp: the tech on the call, or the office / dispatch / an owner pressing it for him
CREATE OR REPLACE FUNCTION public.call_place_set(p_visit bigint, p_kind text, p_lat double precision, p_lng double precision, p_acc numeric DEFAULT NULL) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_user bigint := public.current_app_user_id(); v_role text := public.current_staff_role(); v_emp bigint; v_name text;
BEGIN
  IF v_user IS NULL OR v_role IS NULL THEN RETURN jsonb_build_object('ok', false, 'why', 'not_allowed'); END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('way', 'start', 'end') THEN RETURN jsonb_build_object('ok', false, 'why', 'bad_kind'); END IF;
  IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN RETURN jsonb_build_object('ok', false, 'why', 'no_place'); END IF;
  IF NOT EXISTS (SELECT 1 FROM visits WHERE id = p_visit) THEN RETURN jsonb_build_object('ok', false, 'why', 'no_call'); END IF;
  SELECT u.employee_id, coalesce(nullif(trim(coalesce(e.first_name, '') || ' ' || coalesce(e.last_name, '')), ''), u.login_email)
    INTO v_emp, v_name FROM app_users u LEFT JOIN employees e ON e.id = u.employee_id WHERE u.id = v_user;
  IF v_role NOT IN ('owner', 'admin', 'office', 'dispatcher')
     AND NOT EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id = p_visit AND va.employee_id = v_emp) THEN
    RETURN jsonb_build_object('ok', false, 'why', 'not_allowed'); END IF;
  INSERT INTO on_way_places (visit_id, kind, lat, lng, acc, by_user, by_name) VALUES (p_visit, p_kind, p_lat, p_lng, p_acc, v_user, v_name);
  RETURN jsonb_build_object('ok', true);
END $f$;

-- read the newest stamp of each kind for each call, with the spot of the call's own address (to measure from):
-- owners and dispatch see all; anyone else only the ones they pressed themselves
CREATE OR REPLACE FUNCTION public.call_places_for(p_visits bigint[]) RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object(
      'visit_id', x.visit_id, 'kind', x.kind, 'lat', x.lat, 'lng', x.lng, 'acc', x.acc, 'at', x.at, 'by', x.by_name,
      'to_lat', l.latitude, 'to_lng', l.longitude)) FROM (
    SELECT DISTINCT ON (p.visit_id, p.kind) p.* FROM on_way_places p WHERE p.visit_id = ANY (p_visits)
       AND (public.current_staff_role() = 'owner' OR public.has_permission('calls.dispatch') OR p.by_user = public.current_app_user_id())
     ORDER BY p.visit_id, p.kind, p.at DESC, p.id DESC) x
    LEFT JOIN visits v ON v.id = x.visit_id LEFT JOIN jobs j ON j.id = v.job_id LEFT JOIN locations l ON l.id = j.location_id), '[]'::jsonb) END $f$;

REVOKE EXECUTE ON FUNCTION public.call_place_set(bigint, text, double precision, double precision, numeric), public.call_places_for(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.call_place_set(bigint, text, double precision, double precision, numeric), public.call_places_for(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- The picture in the "On my way" text has a side bar (Carlo, Nov 13, 2026): "Years with REID" and "<name> is a Lead Technician / Service Technician".
-- The years come from the Staff page's "Started working here" (staff_started). The title is a new pick on the Staff page (staff_text_title).
CREATE TABLE IF NOT EXISTS public.staff_text_title (app_user_id bigint PRIMARY KEY, title text NOT NULL, set_by text, set_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.staff_text_title ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.staff_text_title FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.staff_text_title_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.has_permission('staff.manage') OR public.current_staff_role() = 'owner'
    THEN coalesce((SELECT jsonb_agg(jsonb_build_object('user', app_user_id, 'title', title)) FROM staff_text_title), '[]'::jsonb) ELSE '[]'::jsonb END $f$;

CREATE OR REPLACE FUNCTION public.staff_text_title_set(p_user bigint, p_title text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (public.has_permission('staff.manage') OR public.current_staff_role() = 'owner') THEN RAISE EXCEPTION 'You need "Manage staff" to change this'; END IF;
  IF nullif(btrim(p_title), '') IS NULL THEN DELETE FROM staff_text_title WHERE app_user_id = p_user; RETURN; END IF;
  IF p_title NOT IN ('Lead Technician', 'Service Technician') THEN RAISE EXCEPTION 'Pick Lead Technician or Service Technician'; END IF;
  INSERT INTO staff_text_title (app_user_id, title, set_by) VALUES (p_user, p_title, auth.jwt() ->> 'email')
  ON CONFLICT (app_user_id) DO UPDATE SET title = EXCLUDED.title, set_by = EXCLUDED.set_by, set_at = now();
END $function$;

-- what the app needs to draw the picture for one call: the tech (the person pressing when the call is his, else the call's lead), his picture, his years with us and his title
CREATE OR REPLACE FUNCTION public.on_way_card_info(p_visit bigint) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_user bigint := public.current_app_user_id(); v_role text := public.current_staff_role(); v_emp bigint; v_tech bigint; v_tu bigint; v_start date;
BEGIN
  IF v_user IS NULL OR v_role IS NULL THEN RETURN NULL; END IF;
  SELECT employee_id INTO v_emp FROM app_users WHERE id = v_user;
  SELECT va.employee_id INTO v_tech FROM visit_assignments va WHERE va.visit_id = p_visit ORDER BY (va.employee_id IS DISTINCT FROM v_emp), (va.role <> 'lead'), va.id LIMIT 1;
  IF v_tech IS NULL OR (v_tech IS DISTINCT FROM v_emp AND v_role NOT IN ('owner', 'admin', 'office', 'dispatcher')) THEN RETURN NULL; END IF;
  SELECT u.id INTO v_tu FROM app_users u WHERE u.employee_id = v_tech ORDER BY u.id LIMIT 1;
  SELECT started_on INTO v_start FROM staff_started WHERE app_user_id = v_tu;
  RETURN jsonb_build_object('tech', (SELECT nullif(btrim(e.first_name), '') FROM employees e WHERE e.id = v_tech),
    'image', (SELECT p.image FROM staff_photos p WHERE p.app_user_id = v_tu), 'mime', (SELECT coalesce(p.mime, 'image/jpeg') FROM staff_photos p WHERE p.app_user_id = v_tu),
    'years', CASE WHEN v_start IS NOT NULL THEN extract(year FROM age(current_date, v_start))::int END,
    'title', (SELECT title FROM staff_text_title WHERE app_user_id = v_tu));
END $f$;

REVOKE EXECUTE ON FUNCTION public.staff_text_title_list(), public.staff_text_title_set(bigint, text), public.on_way_card_info(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_text_title_list(), public.staff_text_title_set(bigint, text), public.on_way_card_info(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Settings → Eco Man (Carlo, Nov 10: "make a tab in settings for eco man and have all of them posted there so i can pick them
-- and use them as I want for places"). Which Eco Man picture is used in each place, the same for everyone:
-- company_settings.eco_pics = {"update": "eco-3d-walk-move", ...} (place → picture file in eco/, without .webp). A place that is not
-- in it uses its usual picture. Everyone signed in can read it; only an owner can change it.
-- Safe to run more than once.
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS eco_pics jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE OR REPLACE FUNCTION public.eco_pics() RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce((SELECT s.eco_pics FROM company_settings s ORDER BY s.id LIMIT 1), '{}'::jsonb) $f$;
REVOKE EXECUTE ON FUNCTION public.eco_pics() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eco_pics() TO authenticated;

-- p_file null = put the usual picture back for that place
CREATE OR REPLACE FUNCTION public.set_eco_pic(p_place text, p_file text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_old jsonb; v_new jsonb; v_id bigint;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  IF p_place IS NULL OR p_place !~ '^[a-z]{2,20}$' THEN RAISE EXCEPTION 'I do not know that place'; END IF;
  IF p_file IS NOT NULL AND p_file !~ '^eco-3d-[a-z0-9-]{1,40}$' THEN RAISE EXCEPTION 'I do not know that picture'; END IF;
  SELECT s.id, s.eco_pics INTO v_id, v_old FROM company_settings s ORDER BY s.id LIMIT 1;
  IF v_id IS NULL THEN RAISE EXCEPTION 'The company settings are missing'; END IF;
  v_new := CASE WHEN p_file IS NULL THEN coalesce(v_old, '{}'::jsonb) - p_place ELSE coalesce(v_old, '{}'::jsonb) || jsonb_build_object(p_place, p_file) END;
  UPDATE company_settings SET eco_pics = v_new WHERE id = v_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('company_settings', v_id, 'update', public.current_app_user_id(), jsonb_build_object('eco_pics', v_old), jsonb_build_object('eco_pics', v_new));
  RETURN v_new;
END $f$;
REVOKE EXECUTE ON FUNCTION public.set_eco_pic(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_eco_pic(text, text) TO authenticated;

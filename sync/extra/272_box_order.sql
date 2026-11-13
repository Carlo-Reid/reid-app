-- Every page: an owner can hold a box and drag it onto another box of the same section to swap their places; the order is the same for everyone (Carlo, Nov 12, 2026).
-- company_settings.box_order = { "<page>|<path to the section>": { "t": "BUTTON", "o": ["key of a box", …] } }
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS box_order jsonb;
CREATE OR REPLACE FUNCTION public.box_order() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT coalesce((SELECT box_order FROM company_settings ORDER BY id LIMIT 1), '{}'::jsonb) $function$;
CREATE OR REPLACE FUNCTION public.set_box_order(p_key text, p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE cur jsonb;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only an owner can change the order for everyone'; END IF;
  IF p_key IS NULL OR length(p_key) < 3 OR length(p_key) > 800 THEN RAISE EXCEPTION 'That is not a place I can save'; END IF;
  SELECT coalesce(box_order, '{}'::jsonb) INTO cur FROM company_settings ORDER BY id LIMIT 1;
  IF p IS NULL OR jsonb_typeof(p) = 'null' THEN cur := cur - p_key;
  ELSE
    IF jsonb_typeof(p) <> 'object' OR jsonb_typeof(p -> 'o') <> 'array' OR jsonb_array_length(p -> 'o') > 120 OR length(p::text) > 12000 THEN RAISE EXCEPTION 'That is not a list I can save'; END IF;
    IF NOT (cur ? p_key) AND (SELECT count(*) FROM jsonb_object_keys(cur)) >= 400 THEN RAISE EXCEPTION 'There are too many saved orders (400). Put one back first.'; END IF;
    cur := cur || jsonb_build_object(p_key, p);
  END IF;
  UPDATE company_settings SET box_order = cur WHERE id = (SELECT id FROM company_settings ORDER BY id LIMIT 1);
  RETURN cur;
END $function$;
REVOKE EXECUTE ON FUNCTION public.box_order(), public.set_box_order(text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.box_order(), public.set_box_order(text, jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';

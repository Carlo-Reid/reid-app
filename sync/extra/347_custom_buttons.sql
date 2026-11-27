-- Buttons an owner makes himself (Carlo, Nov 27, 2026: "make a way for me to create a button inside the program on the buttons page").
-- company_settings.custom_btns = [ { id, text, pic ("b:<file>" | "u:<id>" | null), act ("page" | "url" | "tel" | "mail"), val,
--   page (the app's page key, or null while it is not put on a page yet), sel ("M <path>" | "S <path>"), at ("after" | "in"),
--   shape ("round" | "square" | "circle"), size ("s" | "m" | "l" | "xl"), color ("#rrggbb" or null = the usual soft look) } ].
-- btn_lib() also answers them as 'custom'. Everyone signed in reads them; only an owner makes, changes or deletes one. Safe to run again.
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS custom_btns jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE OR REPLACE FUNCTION public.btn_lib() RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT jsonb_build_object(
    'pics', coalesce((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'data', p.data) ORDER BY p.id) FROM app_button_pics p), '[]'::jsonb),
    'spots', coalesce((SELECT s.btn_spots FROM company_settings s ORDER BY s.id LIMIT 1), '{}'::jsonb),
    'custom', coalesce((SELECT s.custom_btns FROM company_settings s ORDER BY s.id LIMIT 1), '[]'::jsonb)) $f$;
REVOKE EXECUTE ON FUNCTION public.btn_lib() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.btn_lib() TO authenticated;

-- p = the whole button; a button with the same id is replaced, a new id is added
CREATE OR REPLACE FUNCTION public.btn_custom_set(p jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint; v_l jsonb; v jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  IF coalesce(p->>'id', '') !~ '^[a-z0-9]{4,20}$' THEN RAISE EXCEPTION 'I could not tell which button that is'; END IF;
  IF coalesce(trim(p->>'text'), '') = '' AND coalesce(p->>'pic', '') = '' THEN RAISE EXCEPTION 'Give the button a name or a picture'; END IF;
  IF coalesce(p->>'act', '') NOT IN ('page', 'url', 'tel', 'mail') THEN RAISE EXCEPTION 'Pick what the button does'; END IF;
  IF coalesce(trim(p->>'val'), '') = '' THEN RAISE EXCEPTION 'Fill in where the button goes'; END IF;
  IF p->>'act' = 'url' AND p->>'val' !~* '^https?://' THEN RAISE EXCEPTION 'A web address starts with https://'; END IF;
  IF length(p::text) > 3000 THEN RAISE EXCEPTION 'That is too long'; END IF;
  v := jsonb_build_object('id', p->>'id', 'text', left(nullif(trim(p->>'text'), ''), 80), 'pic', nullif(p->>'pic', ''), 'act', p->>'act',
         'val', left(trim(p->>'val'), 500), 'page', nullif(p->>'page', ''), 'sel', left(nullif(p->>'sel', ''), 800), 'at', CASE WHEN p->>'at' = 'in' THEN 'in' ELSE 'after' END,
         'shape', CASE WHEN p->>'shape' IN ('square', 'circle') THEN p->>'shape' ELSE 'round' END,
         'size', CASE WHEN p->>'size' IN ('s', 'l', 'xl') THEN p->>'size' ELSE 'm' END,
         'color', CASE WHEN p->>'color' ~ '^#[0-9a-fA-F]{6}$' THEN lower(p->>'color') ELSE NULL END);
  SELECT s.id, coalesce(s.custom_btns, '[]'::jsonb) INTO v_id, v_l FROM company_settings s ORDER BY s.id LIMIT 1;
  IF v_id IS NULL THEN RAISE EXCEPTION 'No company settings row'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_l) e WHERE e->>'id' = v->>'id') AND jsonb_array_length(v_l) >= 200 THEN
    RAISE EXCEPTION 'That is a lot of buttons (200). Delete one first.'; END IF;
  SELECT coalesce(jsonb_agg(CASE WHEN e->>'id' = v->>'id' THEN v ELSE e END), '[]'::jsonb) INTO v_l FROM jsonb_array_elements(v_l) e;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_l) e WHERE e->>'id' = v->>'id') THEN v_l := v_l || jsonb_build_array(v); END IF;
  UPDATE company_settings SET custom_btns = v_l WHERE id = v_id;
  RETURN public.btn_lib();
END $f$;
REVOKE EXECUTE ON FUNCTION public.btn_custom_set(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.btn_custom_set(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.btn_custom_del(p_id text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint; v_l jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  SELECT s.id, coalesce(s.custom_btns, '[]'::jsonb) INTO v_id, v_l FROM company_settings s ORDER BY s.id LIMIT 1;
  IF v_id IS NULL THEN RETURN public.btn_lib(); END IF;
  SELECT coalesce(jsonb_agg(e), '[]'::jsonb) INTO v_l FROM jsonb_array_elements(v_l) e WHERE e->>'id' IS DISTINCT FROM p_id;
  UPDATE company_settings SET custom_btns = v_l WHERE id = v_id;
  RETURN public.btn_lib();
END $f$;
REVOKE EXECUTE ON FUNCTION public.btn_custom_del(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.btn_custom_del(text) TO authenticated;

-- Buttons (Carlo, Nov 27, 2026: "add a tab on the settings page and call it Buttons and have a way for me to load buttons to it…
-- when I double click a button and hold on the second click a pop asks if I want to change the button… also have it so I can edit the
-- text in the button on the page even if I do not change the button").
-- app_button_pics = the button pictures an owner loads (a small picture kept as a data address). The pictures built into the app
-- (logos/*.png) are not in here: the app lists them itself.
-- company_settings.btn_spots = { "<key>": { "pic": "b:<file>" | "u:<id>", "text": "<words>", "page": "...", "name": "..." } }:
--   a key "spot:<name>" is one of the app's picture buttons; any other key is "<page>|<root> <path>" of a button on a page, the same
--   way the copy buttons and Eco Man spots find their place. Everyone signed in reads them; only an owner changes them.
-- Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.app_button_pics (
  id bigserial PRIMARY KEY,
  name text NOT NULL,
  data text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid DEFAULT auth.uid()
);
ALTER TABLE public.app_button_pics ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.app_button_pics FROM anon, authenticated;
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS btn_spots jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE OR REPLACE FUNCTION public.btn_lib() RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT jsonb_build_object(
    'pics', coalesce((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'data', p.data) ORDER BY p.id) FROM app_button_pics p), '[]'::jsonb),
    'spots', coalesce((SELECT s.btn_spots FROM company_settings s ORDER BY s.id LIMIT 1), '{}'::jsonb)) $f$;
REVOKE EXECUTE ON FUNCTION public.btn_lib() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.btn_lib() TO authenticated;

CREATE OR REPLACE FUNCTION public.btn_pic_add(p_name text, p_data text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  IF coalesce(p_data, '') !~ '^data:image/(png|jpeg|webp|gif);base64,' THEN RAISE EXCEPTION 'That is not a picture'; END IF;
  IF length(p_data) > 1500000 THEN RAISE EXCEPTION 'That picture is too big. Use a smaller one.'; END IF;
  IF (SELECT count(*) FROM app_button_pics) >= 300 THEN RAISE EXCEPTION 'That is a lot of button pictures (300). Delete one first.'; END IF;
  INSERT INTO app_button_pics (name, data) VALUES (left(coalesce(nullif(trim(p_name), ''), 'Button'), 80), p_data);
  RETURN public.btn_lib();
END $f$;
REVOKE EXECUTE ON FUNCTION public.btn_pic_add(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.btn_pic_add(text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.btn_pic_rename(p_id bigint, p_name text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  IF coalesce(trim(p_name), '') = '' THEN RAISE EXCEPTION 'Type a name'; END IF;
  UPDATE app_button_pics SET name = left(trim(p_name), 80) WHERE id = p_id;
  RETURN public.btn_lib();
END $f$;
REVOKE EXECUTE ON FUNCTION public.btn_pic_rename(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.btn_pic_rename(bigint, text) TO authenticated;

-- a picture that is deleted is also taken off every button that used it (those buttons show their usual picture again)
CREATE OR REPLACE FUNCTION public.btn_pic_del(p_id bigint) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint; v_sp jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
    SELECT 'app_button_pics', p.id, 'delete', auth.uid(), jsonb_build_object('name', p.name), NULL FROM app_button_pics p WHERE p.id = p_id;
  DELETE FROM app_button_pics WHERE id = p_id;
  SELECT s.id, coalesce(s.btn_spots, '{}'::jsonb) INTO v_id, v_sp FROM company_settings s ORDER BY s.id LIMIT 1;
  IF v_id IS NOT NULL THEN
    SELECT coalesce(jsonb_object_agg(k, CASE WHEN v->>'pic' = 'u:' || p_id THEN v - 'pic' ELSE v END) FILTER (WHERE NOT (v->>'pic' = 'u:' || p_id AND (v - 'pic' - 'page' - 'name') = '{}'::jsonb)), '{}'::jsonb)
      INTO v_sp FROM jsonb_each(v_sp) e(k, v);
    UPDATE company_settings SET btn_spots = v_sp WHERE id = v_id;
  END IF;
  RETURN public.btn_lib();
END $f$;
REVOKE EXECUTE ON FUNCTION public.btn_pic_del(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.btn_pic_del(bigint) TO authenticated;

-- p = { pic?, text?, page?, name? }; p null (or with neither pic nor text) takes the button back to how the app draws it
CREATE OR REPLACE FUNCTION public.btn_spot_set(p_key text, p jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint; v_sp jsonb; v jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  IF length(coalesce(p_key, '')) NOT BETWEEN 3 AND 800 THEN RAISE EXCEPTION 'I could not tell which button that is'; END IF;
  SELECT s.id, coalesce(s.btn_spots, '{}'::jsonb) INTO v_id, v_sp FROM company_settings s ORDER BY s.id LIMIT 1;
  IF v_id IS NULL THEN RAISE EXCEPTION 'The company settings are missing'; END IF;
  v := NULL;
  IF p IS NOT NULL AND jsonb_typeof(p) = 'object' THEN
    v := jsonb_strip_nulls(jsonb_build_object(
      'pic', CASE WHEN p->>'pic' ~ '^(b:[a-z0-9-]{1,60}|u:[0-9]{1,12})$' THEN p->>'pic' END,
      'text', nullif(left(trim(coalesce(p->>'text', '')), 120), ''),
      'page', left(p->>'page', 60), 'name', left(p->>'name', 120)));
    IF NOT (v ? 'pic' OR v ? 'text') THEN v := NULL; END IF;
  END IF;
  IF v IS NULL THEN v_sp := v_sp - p_key;
  ELSE
    IF NOT v_sp ? p_key AND (SELECT count(*) FROM jsonb_object_keys(v_sp)) >= 600 THEN RAISE EXCEPTION 'That is a lot of changed buttons (600). Put one back first.'; END IF;
    v_sp := v_sp || jsonb_build_object(p_key, v);
  END IF;
  UPDATE company_settings SET btn_spots = v_sp WHERE id = v_id;
  RETURN public.btn_lib();
END $f$;
REVOKE EXECUTE ON FUNCTION public.btn_spot_set(text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.btn_spot_set(text, jsonb) TO authenticated;

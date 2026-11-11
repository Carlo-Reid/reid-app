-- Eco Men that are part of a page and were taken off it by an owner (Carlo, Nov 11, 2026: "when an eco man is on the page and I open the
-- Eco Man setting button have a way for me to click on one and delete it from the page without leaving the page").
-- company_settings.eco_hidden = a list of {id, page, sel}: the page (the app's page key) and a path to the piece of the page he sits in.
-- The app does not draw the Eco Man pictures in that piece. Everyone signed in gets the list; only an owner can change it.
-- No customer data in here. Safe to run more than once.
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS eco_hidden jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE OR REPLACE FUNCTION public.eco_hidden() RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce((SELECT s.eco_hidden FROM company_settings s ORDER BY s.id LIMIT 1), '[]'::jsonb) $f$;
REVOKE EXECUTE ON FUNCTION public.eco_hidden() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eco_hidden() TO authenticated;

-- p = {page, sel}. Returns the whole list.
CREATE OR REPLACE FUNCTION public.eco_hide_add(p jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint; v_old jsonb; v_new jsonb; v_n int;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  IF coalesce(p->>'page', '') !~ '^[a-z0-9=_-]{1,40}$' THEN RAISE EXCEPTION 'I do not know that page'; END IF;
  IF length(coalesce(p->>'sel', '')) NOT BETWEEN 1 AND 700 THEN RAISE EXCEPTION 'I could not tell which spot that is'; END IF;
  SELECT s.id, coalesce(s.eco_hidden, '[]'::jsonb) INTO v_id, v_old FROM company_settings s ORDER BY s.id LIMIT 1;
  IF v_id IS NULL THEN RAISE EXCEPTION 'The company settings are missing'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_old) x WHERE x->>'page' = p->>'page' AND x->>'sel' = p->>'sel') THEN RETURN v_old; END IF;
  IF jsonb_array_length(v_old) >= 200 THEN RAISE EXCEPTION 'That is a lot taken off (200). Put some back first.'; END IF;
  v_n := coalesce((SELECT max((x->>'id')::int) FROM jsonb_array_elements(v_old) x), 0) + 1;
  v_new := v_old || jsonb_build_array(jsonb_build_object('id', v_n, 'page', p->>'page', 'sel', p->>'sel'));
  UPDATE company_settings SET eco_hidden = v_new WHERE id = v_id;
  RETURN v_new;
END $f$;
REVOKE EXECUTE ON FUNCTION public.eco_hide_add(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eco_hide_add(jsonb) TO authenticated;

-- puts back every one taken off that page. Returns the whole list.
CREATE OR REPLACE FUNCTION public.eco_hide_clear(p_page text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint; v_new jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  SELECT s.id, coalesce((SELECT jsonb_agg(x ORDER BY (x->>'id')::int) FROM jsonb_array_elements(coalesce(s.eco_hidden, '[]'::jsonb)) x WHERE x->>'page' IS DISTINCT FROM p_page), '[]'::jsonb)
    INTO v_id, v_new FROM company_settings s ORDER BY s.id LIMIT 1;
  UPDATE company_settings SET eco_hidden = v_new WHERE id = v_id;
  RETURN v_new;
END $f$;
REVOKE EXECUTE ON FUNCTION public.eco_hide_clear(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eco_hide_clear(text) TO authenticated;

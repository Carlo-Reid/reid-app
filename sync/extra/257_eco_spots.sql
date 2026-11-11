-- Eco Man put on a page by hand (Carlo, Nov 10, 2026: "when I click the eco man button have a button open as an option to add him to a page;
-- when I click on a location it lets me choose the eco man I want to use"). company_settings.eco_spots = a list of
-- {id, page, sel, fx, fy, file, size}: the page (the app's page key), the spot (a path to the piece of the page that was clicked, and where
-- in it, in percent), the picture (a file in eco/, without .webp) and its size (s, m, l). Everyone signed in sees them; only an owner can
-- add, change or take one off. No customer data in here. Safe to run more than once.
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS eco_spots jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE OR REPLACE FUNCTION public.eco_spots() RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce((SELECT s.eco_spots FROM company_settings s ORDER BY s.id LIMIT 1), '[]'::jsonb) $f$;
REVOKE EXECUTE ON FUNCTION public.eco_spots() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eco_spots() TO authenticated;

-- p = {id?, page, sel, fx, fy, file, size}: no id = a new one. Returns the whole list.
CREATE OR REPLACE FUNCTION public.eco_spot_set(p jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint; v_old jsonb; v_new jsonb; v_sid int := nullif(p->>'id', '')::int; v_one jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  IF coalesce(p->>'page', '') !~ '^[a-z0-9=_-]{1,40}$' THEN RAISE EXCEPTION 'I do not know that page'; END IF;
  IF coalesce(p->>'file', '') !~ '^eco-3d-[a-z0-9-]{1,40}$' THEN RAISE EXCEPTION 'I do not know that picture'; END IF;
  IF length(coalesce(p->>'sel', '')) NOT BETWEEN 1 AND 700 THEN RAISE EXCEPTION 'I could not tell which spot that is'; END IF;
  -- the size: s, m, l, or (from the slider, Nov 10) a height in pixels from 40 to 400
  IF coalesce(p->>'size', 'm') NOT IN ('s', 'm', 'l') AND NOT (p->>'size' ~ '^[0-9]{2,3}$' AND (p->>'size')::int BETWEEN 40 AND 400) THEN RAISE EXCEPTION 'The size has to be small, medium or large, or a number from 40 to 400'; END IF;
  SELECT s.id, coalesce(s.eco_spots, '[]'::jsonb) INTO v_id, v_old FROM company_settings s ORDER BY s.id LIMIT 1;
  IF v_id IS NULL THEN RAISE EXCEPTION 'The company settings are missing'; END IF;
  IF v_sid IS NULL THEN
    IF jsonb_array_length(v_old) >= 60 THEN RAISE EXCEPTION 'That is a lot of Eco Men (60). Take one off first.'; END IF;
    v_sid := coalesce((SELECT max((x->>'id')::int) FROM jsonb_array_elements(v_old) x), 0) + 1;
  END IF;
  v_one := jsonb_build_object('id', v_sid, 'page', p->>'page', 'sel', p->>'sel', 'file', p->>'file', 'size', coalesce(p->>'size', 'm'),
    'fx', greatest(0, least(100, coalesce((p->>'fx')::numeric, 50))), 'fy', greatest(0, least(100, coalesce((p->>'fy')::numeric, 50))));
  v_new := coalesce((SELECT jsonb_agg(x ORDER BY (x->>'id')::int) FROM jsonb_array_elements(v_old) x WHERE (x->>'id')::int <> v_sid), '[]'::jsonb) || jsonb_build_array(v_one);
  UPDATE company_settings SET eco_spots = v_new WHERE id = v_id;
  RETURN v_new;
END $f$;
REVOKE EXECUTE ON FUNCTION public.eco_spot_set(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eco_spot_set(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.eco_spot_del(p_id int) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint; v_new jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  SELECT s.id, coalesce((SELECT jsonb_agg(x ORDER BY (x->>'id')::int) FROM jsonb_array_elements(coalesce(s.eco_spots, '[]'::jsonb)) x WHERE (x->>'id')::int <> p_id), '[]'::jsonb)
    INTO v_id, v_new FROM company_settings s ORDER BY s.id LIMIT 1;
  UPDATE company_settings SET eco_spots = v_new WHERE id = v_id;
  RETURN v_new;
END $f$;
REVOKE EXECUTE ON FUNCTION public.eco_spot_del(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eco_spot_del(int) TO authenticated;

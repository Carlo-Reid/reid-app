-- Copy buttons an owner puts on a page (Carlo, Nov 12, 2026: "a button at the top bar… click on a word, name or number, or select an area,
-- and hit add, and it now has a copy button; only for owners, and it applies to everyone"). company_settings.copy_spots = a list of
-- {id, page, sel}: the page (the app's page key) and the path to the piece of the page (as the Eco Man spots use). Everyone signed in gets
-- the buttons; only an owner can add or take one off. No customer data in here. Safe to run more than once.
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS copy_spots jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE OR REPLACE FUNCTION public.copy_spots() RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce((SELECT s.copy_spots FROM company_settings s ORDER BY s.id LIMIT 1), '[]'::jsonb) $f$;
REVOKE EXECUTE ON FUNCTION public.copy_spots() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.copy_spots() TO authenticated;

CREATE OR REPLACE FUNCTION public.copy_spot_add(p jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint; v_old jsonb; v_new jsonb; v_sid int;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  IF coalesce(p->>'page', '') !~ '^[a-z0-9=_-]{1,40}$' THEN RAISE EXCEPTION 'I do not know that page'; END IF;
  IF length(coalesce(p->>'sel', '')) NOT BETWEEN 1 AND 700 THEN RAISE EXCEPTION 'I could not tell which spot that is'; END IF;
  SELECT s.id, coalesce(s.copy_spots, '[]'::jsonb) INTO v_id, v_old FROM company_settings s ORDER BY s.id LIMIT 1;
  IF v_id IS NULL THEN RAISE EXCEPTION 'The company settings are missing'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_old) x WHERE x->>'page' = p->>'page' AND x->>'sel' = p->>'sel') THEN RETURN v_old; END IF;
  IF jsonb_array_length(v_old) >= 300 THEN RAISE EXCEPTION 'That is a lot of copy buttons (300). Take one off first.'; END IF;
  v_sid := coalesce((SELECT max((x->>'id')::int) FROM jsonb_array_elements(v_old) x), 0) + 1;
  v_new := v_old || jsonb_build_array(jsonb_build_object('id', v_sid, 'page', p->>'page', 'sel', p->>'sel'));
  UPDATE company_settings SET copy_spots = v_new WHERE id = v_id;
  RETURN v_new;
END $f$;
REVOKE EXECUTE ON FUNCTION public.copy_spot_add(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.copy_spot_add(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.copy_spot_del(p_id int) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint; v_new jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  SELECT s.id, coalesce((SELECT jsonb_agg(x ORDER BY (x->>'id')::int) FROM jsonb_array_elements(coalesce(s.copy_spots, '[]'::jsonb)) x WHERE (x->>'id')::int <> p_id), '[]'::jsonb)
    INTO v_id, v_new FROM company_settings s ORDER BY s.id LIMIT 1;
  UPDATE company_settings SET copy_spots = v_new WHERE id = v_id;
  RETURN v_new;
END $f$;
REVOKE EXECUTE ON FUNCTION public.copy_spot_del(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.copy_spot_del(int) TO authenticated;

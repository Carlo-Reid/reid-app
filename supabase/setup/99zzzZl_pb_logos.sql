-- copy of sync/extra/052_pb_logos.sql (run by the nightly sync)
-- Price book tools: Logos. A library of logos (uploaded once), that can be put anywhere on an equipment item's picture card
-- (dragged into place and sized). Where they sit is kept with the item's own picture boxes: layout.logos = [{l, x, y, w}]
-- (l = logo id; x, y = top-left corner and w = width, all in % of the card).
CREATE TABLE IF NOT EXISTS public.pb_logos (
  id bigserial PRIMARY KEY, name text NOT NULL, image text NOT NULL, active boolean NOT NULL DEFAULT true,
  created_by bigint, created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.pb_logos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pb_logos FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.pb_logos_list()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(jsonb_build_object('id', id, 'name', name, 'image', image) ORDER BY id) FROM pb_logos WHERE active), '[]'::jsonb) END
$$;

CREATE OR REPLACE FUNCTION public.pb_logo_add(p_name text, p_image text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v bigint;
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF coalesce(btrim(p_name), '') = '' THEN RAISE EXCEPTION 'Give the logo a name'; END IF;
  IF p_image !~ '^data:image/(png|jpeg|webp);base64,' OR length(p_image) > 1500000 THEN RAISE EXCEPTION 'That picture can''t be used as a logo'; END IF;
  INSERT INTO pb_logos (name, image, created_by) VALUES (left(btrim(p_name), 60), p_image, public.current_app_user_id()) RETURNING id INTO v;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('pb_logos', v, 'insert', public.current_app_user_id(), jsonb_build_object('name', p_name));
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.pb_logo_set(p_id bigint, p_name text, p_active boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  UPDATE pb_logos SET name = coalesce(nullif(left(btrim(p_name), 60), ''), name), active = coalesce(p_active, active) WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('pb_logos', p_id, 'update', public.current_app_user_id(), jsonb_build_object('name', p_name, 'active', p_active));
END $$;
REVOKE EXECUTE ON FUNCTION public.pb_logos_list(), public.pb_logo_add(text, text), public.pb_logo_set(bigint, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_logos_list(), public.pb_logo_add(text, text), public.pb_logo_set(bigint, text, boolean) TO authenticated;

-- one item's own boxes: now also keeps where its logos sit
CREATE OR REPLACE FUNCTION public.save_pb_item_boxes(p_item bigint, p jsonb, p_layout jsonb DEFAULT '{}'::jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v jsonb; lay jsonb; w text := p_layout ->> 'w'; lg jsonb;
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pricebook_items WHERE id = p_item) THEN RAISE EXCEPTION 'Item not found'; END IF;
  IF p IS NULL THEN
    DELETE FROM pb_item_boxes WHERE item_id = p_item;
  ELSE
    v := public._clean_callouts(p);
    lay := CASE WHEN w IN ('S', 'M', 'L', 'XL') OR (w ~ '^[0-9](\.[0-9]{1,2})?$' AND w::numeric BETWEEN 0.4 AND 3) THEN jsonb_build_object('w', w) ELSE '{}'::jsonb END;
    IF jsonb_typeof(p_layout -> 'logos') = 'array' THEN
      SELECT jsonb_agg(jsonb_build_object('l', (e ->> 'l')::bigint,
               'x', round(least(greatest((e ->> 'x')::numeric, -20), 100), 2), 'y', round(least(greatest((e ->> 'y')::numeric, -20), 100), 2),
               'w', round(least(greatest((e ->> 'w')::numeric, 3), 100), 2)) ORDER BY o)
        INTO lg
        FROM jsonb_array_elements(p_layout -> 'logos') WITH ORDINALITY AS t(e, o)
       WHERE o <= 12 AND (e ->> 'l') ~ '^[0-9]+$' AND (e ->> 'x') ~ '^-?[0-9.]+$' AND (e ->> 'y') ~ '^-?[0-9.]+$' AND (e ->> 'w') ~ '^[0-9.]+$';
      IF lg IS NOT NULL THEN lay := lay || jsonb_build_object('logos', lg); END IF;
    END IF;
    INSERT INTO pb_item_boxes (item_id, callouts, layout, updated_by) VALUES (p_item, v, lay, public.current_app_user_id())
    ON CONFLICT (item_id) DO UPDATE SET callouts = EXCLUDED.callouts, layout = EXCLUDED.layout, updated_at = now(), updated_by = EXCLUDED.updated_by;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pricebook_items', p_item, 'update', public.current_app_user_id(),
          jsonb_build_object('change', CASE WHEN p IS NULL THEN 'own picture boxes taken off (uses the shared ones)' ELSE 'own picture boxes saved' END));
END $$;
NOTIFY pgrst, 'reload schema';

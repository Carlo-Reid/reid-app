-- 99zzzZe: picture box sizes by dragging. Also runs every night from sync/extra/045_box_drag_sizes.sql. Safe to run more than once.
-- Picture boxes: sizes set by dragging. A box's height (style h) can be a number (0.3 to 4, "how many normal boxes tall"),
-- and the boxes' width next to the picture (layout w) a number (0.4 to 3), as well as the old steps (0 / S / L / XL and S / M / L / XL).
CREATE OR REPLACE FUNCTION public._clean_callouts(p jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_agg(
           CASE WHEN jsonb_typeof(e) = 'object' THEN jsonb_build_object(
                  'text', left(coalesce(e ->> 'text', ''), 400),
                  'style', (SELECT coalesce(jsonb_object_agg(k, left(val, 40)), '{}'::jsonb)
                            FROM jsonb_each_text(coalesce(e -> 'style', '{}'::jsonb)) s(k, val)
                            WHERE k IN ('color', 'bg', 'bold', 'italic', 'underline', 'size', 'font', 'align', 'border', 'shadow', 'caps', 'h')
                              AND val ~ '^[#A-Za-z0-9 .,()-]{0,40}$'
                              AND (k <> 'h' OR val IN ('0', 'S', 'L', 'XL')
                                   OR (val ~ '^[0-9](\.[0-9]{1,2})?$' AND val::numeric BETWEEN 0.3 AND 4))))
                ELSE to_jsonb(left(coalesce(e #>> '{}', ''), 400)) END ORDER BY n), '[]')
  FROM jsonb_array_elements(coalesce(p, '[]')) WITH ORDINALITY x(e, n) WHERE n <= 8
$$;

CREATE OR REPLACE FUNCTION public.save_pb_item_boxes(p_item bigint, p jsonb, p_layout jsonb DEFAULT '{}'::jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v jsonb; lay jsonb; w text := p_layout ->> 'w';
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pricebook_items WHERE id = p_item) THEN RAISE EXCEPTION 'Item not found'; END IF;
  IF p IS NULL THEN
    DELETE FROM pb_item_boxes WHERE item_id = p_item;
  ELSE
    v := public._clean_callouts(p);
    lay := CASE WHEN w IN ('S', 'M', 'L', 'XL') OR (w ~ '^[0-9](\.[0-9]{1,2})?$' AND w::numeric BETWEEN 0.4 AND 3) THEN jsonb_build_object('w', w) ELSE '{}'::jsonb END;
    INSERT INTO pb_item_boxes (item_id, callouts, layout, updated_by) VALUES (p_item, v, lay, public.current_app_user_id())
    ON CONFLICT (item_id) DO UPDATE SET callouts = EXCLUDED.callouts, layout = EXCLUDED.layout, updated_at = now(), updated_by = EXCLUDED.updated_by;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pricebook_items', p_item, 'update', public.current_app_user_id(),
          jsonb_build_object('change', CASE WHEN p IS NULL THEN 'own picture boxes taken off (uses the shared ones)' ELSE 'own picture boxes saved' END));
END $$;
NOTIFY pgrst, 'reload schema';

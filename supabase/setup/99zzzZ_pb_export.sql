-- 99zzzZ: price book to Excel (every item). Also runs every night from sync/extra/041_pb_export.sql. Safe to run more than once.
-- Price book to Excel: every item in one go (the normal list stops at 1,000), for people who can edit the price book.
-- Costs only for people who can see costs. Category = the full path ("Furnaces > Lennox SLP99VK"); several are joined with " | ".
CREATE OR REPLACE FUNCTION public.pb_export()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
DECLARE v_cost boolean := public._can_see_costs(); out jsonb;
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You need "Edit the price book" to export it'; END IF;
  WITH RECURSIVE path AS (
    SELECT c.id, c.name::text AS p FROM pricebook_categories c WHERE c.parent_id IS NULL
    UNION ALL SELECT c.id, path.p || ' > ' || c.name FROM pricebook_categories c JOIN path ON c.parent_id = path.id)
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'item_type', p.item_type, 'sku', p.sku, 'name', p.name, 'description', p.description, 'unit_of_measure', p.unit_of_measure,
           'unit_price', p.unit_price, 'unit_cost', CASE WHEN v_cost THEN p.unit_cost END, 'member_price', p.member_price,
           'taxable', p.taxable, 'active', p.active, 'est_labour_hours', p.est_labour_hours,
           'supplier', btrim(sp.name), 'manufacturer', p.manufacturer, 'model', p.model_number,
           'categories', (SELECT string_agg(path.p, ' | ' ORDER BY path.p) FROM pricebook_item_categories ic JOIN path ON path.id = ic.category_id WHERE ic.item_id = p.id))
         ORDER BY p.active DESC, p.item_type, p.name), '[]'::jsonb)
  INTO out
  FROM pricebook_items p LEFT JOIN suppliers sp ON sp.id = p.preferred_supplier_id
  WHERE NOT p.pending_new;
  RETURN jsonb_build_object('items', out, 'costs', v_cost,
    'categories', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'path', p) ORDER BY p), '[]'::jsonb) FROM path));
END $function$;
REVOKE EXECUTE ON FUNCTION public.pb_export() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_export() TO authenticated;
NOTIFY pgrst, 'reload schema';

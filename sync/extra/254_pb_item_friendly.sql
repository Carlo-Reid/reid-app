-- The part's page, made friendlier (Carlo, Nov 10: "do it all"). Two small things need the database:
--   1. "Tell me to order when we have fewer than …": one number on each item (pricebook_items.reorder_below), so the Stock section
--      can say "We have 46. Good." or "We have 2. Time to order."
--   2. "What changed?": the last changes to an item in a form the app can put in plain words (who, when, what it was, what it is now).
-- Safe to run more than once.
ALTER TABLE public.pricebook_items ADD COLUMN IF NOT EXISTS reorder_below numeric;

CREATE OR REPLACE FUNCTION public.pb_reorder(p_item bigint) RETURNS numeric
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE (SELECT i.reorder_below FROM pricebook_items i WHERE i.id = p_item) END $f$;

CREATE OR REPLACE FUNCTION public.set_pb_reorder(p_item bigint, p_n numeric) RETURNS numeric
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_old numeric;
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF p_n IS NOT NULL AND (p_n < 0 OR p_n > 1000000) THEN RAISE EXCEPTION 'Type a number from 0 up, or leave it empty'; END IF;
  SELECT reorder_below INTO v_old FROM pricebook_items WHERE id = p_item;
  IF NOT FOUND THEN RAISE EXCEPTION 'That item is not in the price book'; END IF;
  UPDATE pricebook_items SET reorder_below = p_n WHERE id = p_item;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('pricebook_items', p_item, 'update', public.current_app_user_id(), jsonb_build_object('reorder_below', v_old), jsonb_build_object('reorder_below', p_n));
  RETURN p_n;
END $f$;

CREATE OR REPLACE FUNCTION public.pb_item_changes(p_item bigint) RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('at', x.at, 'who', x.who, 'what', x.act,
             'was', CASE WHEN public._can_see_costs() THEN x.was ELSE x.was - 'unit_cost' END,
             'now', CASE WHEN public._can_see_costs() THEN x.now ELSE x.now - 'unit_cost' END) ORDER BY x.at DESC)
    FROM (
      SELECT a.changed_at AS at, public._staff_name(a.changed_by_user_id) AS who, a.action AS act,
        CASE WHEN a.old_values IS NULL THEN '{}'::jsonb ELSE
          (SELECT coalesce(jsonb_object_agg(k, a.old_values -> k), '{}'::jsonb) FROM jsonb_object_keys(coalesce(a.new_values, '{}'::jsonb)) k
            WHERE k NOT IN ('updated_at', 'change', 'why', 'description_html') AND a.old_values ? k AND a.old_values -> k IS DISTINCT FROM a.new_values -> k) END AS was,
        (SELECT coalesce(jsonb_object_agg(k, a.new_values -> k), '{}'::jsonb) FROM jsonb_object_keys(coalesce(a.new_values, '{}'::jsonb)) k
          WHERE k IN ('change', 'why')
             OR (k NOT IN ('updated_at', 'description_html') AND a.old_values IS NOT NULL AND a.old_values ? k AND a.old_values -> k IS DISTINCT FROM a.new_values -> k)
             OR (a.old_values IS NULL AND k IN ('unit_cost', 'unit_price', 'name'))) AS now
      FROM audit_log a WHERE a.table_name = 'pricebook_items' AND a.row_id = p_item
      ORDER BY a.changed_at DESC LIMIT 30) x
    WHERE x.now <> '{}'::jsonb), '[]'::jsonb) END $f$;

REVOKE EXECUTE ON FUNCTION public.pb_reorder(bigint), public.set_pb_reorder(bigint, numeric), public.pb_item_changes(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_reorder(bigint), public.set_pb_reorder(bigint, numeric), public.pb_item_changes(bigint) TO authenticated;

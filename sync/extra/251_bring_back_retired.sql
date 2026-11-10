-- A retired part that is bought again comes back by itself (Carlo, Nov 10: "the system should bring any part back that has been
-- retired but is purchased again"). Two places see a purchase:
--   1. a supplier's paper (invoice, packing slip, emailed paper) with the part on it: _add_cost_update is called for every such line;
--   2. a purchase order line for the part.
-- Only for a purchase in the last 90 days, so loading old papers or an old PO does not bring back things retired since.
-- Each one is written in audit_log (action 'update', new_values.why says "Bought again: …"), so it can be seen and undone. Safe to run more than once.
CREATE OR REPLACE FUNCTION public._pb_bring_back(p_item bigint, p_why text) RETURNS boolean
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int;
BEGIN
  UPDATE pricebook_items SET active = true WHERE id = p_item AND NOT active AND NOT pending_new;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RETURN false; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('pricebook_items', p_item, 'update', public.current_app_user_id(), jsonb_build_object('active', false), jsonb_build_object('active', true, 'why', left(p_why, 300)));
  RETURN true;
END $f$;
REVOKE EXECUTE ON FUNCTION public._pb_bring_back(bigint, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._add_cost_update(p_sku text, p_supplier text, p_code text, p_desc text, p_cost numeric, p_ref text, p_date date)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE it pricebook_items; n int; v_foot numeric; v_cost numeric := p_cost; v_desc text := p_desc;
BEGIN
  SELECT * INTO it FROM pricebook_items WHERE sku = p_sku ORDER BY active DESC, id DESC LIMIT 1;
  IF it.id IS NULL THEN RETURN 'not in price book'; END IF;
  -- retired, and bought again: it comes back
  IF NOT it.active AND NOT it.pending_new AND coalesce(p_date, current_date) > current_date - 90 THEN
    PERFORM public._pb_bring_back(it.id, 'Bought again: ' || coalesce(p_supplier, '') || ' ' || coalesce(p_ref, '')); END IF;
  v_foot := public._cost_per_foot(it.id, p_cost);
  IF v_foot IS NOT NULL THEN v_cost := v_foot;
    v_desc := left(coalesce(p_desc, ''), 150) || ' [roll $' || trim(to_char(p_cost, 'FM999999990.00')) || ' ÷ ' || trim(to_char(it.unit_length, 'FM999999990.##')) || ' ft]'; END IF;
  IF EXISTS (SELECT 1 FROM pricebook_cost_updates WHERE item_id = it.id AND status = 'waiting' AND doc_date > p_date) THEN RETURN 'older'; END IF;
  IF abs(coalesce(it.unit_cost, 0) - v_cost) < 0.005 THEN RETURN 'same'; END IF;
  IF EXISTS (SELECT 1 FROM pricebook_cost_updates WHERE item_id = it.id AND supplier = p_supplier AND doc_ref = p_ref) THEN RETURN 'already there'; END IF;
  UPDATE pricebook_cost_updates SET status = 'replaced' WHERE item_id = it.id AND status = 'waiting' AND doc_ref <> p_ref;
  INSERT INTO pricebook_cost_updates (item_id, supplier, supplier_code, description, old_cost, new_cost, doc_ref, doc_date)
  VALUES (it.id, p_supplier, p_code, v_desc, it.unit_cost, v_cost, p_ref, p_date)
  ON CONFLICT (item_id, supplier, doc_ref) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN CASE WHEN n > 0 THEN 'added' ELSE 'already there' END;
END $function$;

-- a PO line for a retired part
CREATE OR REPLACE FUNCTION public._po_line_bring_back() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE o purchase_orders;
BEGIN
  IF NEW.item_id IS NULL OR NOT EXISTS (SELECT 1 FROM pricebook_items WHERE id = NEW.item_id AND NOT active AND NOT pending_new) THEN RETURN NEW; END IF;
  SELECT * INTO o FROM purchase_orders WHERE id = NEW.purchase_order_id;
  IF coalesce(o.status, '') !~* 'cancel' AND coalesce(o.ordered_at, o.created_at, now()) > now() - interval '90 days' THEN
    PERFORM public._pb_bring_back(NEW.item_id, 'Bought again: PO ' || coalesce(o.po_number, '')); END IF;
  RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS po_line_bring_back ON purchase_order_lines;
CREATE TRIGGER po_line_bring_back AFTER INSERT OR UPDATE OF item_id ON purchase_order_lines FOR EACH ROW EXECUTE FUNCTION public._po_line_bring_back();

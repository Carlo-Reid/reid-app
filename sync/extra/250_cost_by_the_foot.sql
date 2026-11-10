-- Approvals: an item sold by the foot gets its new cost by the foot (Carlo, Nov 10). A supplier's paper gives the price of the whole roll
-- ($51.50 for 250 ft of thermostat wire); approving that as it was would have made the cost $51.50 A FOOT. When the item is sold by the
-- foot and "feet bought" is filled in (pricebook_items.unit_length), the paper's price is divided by the feet bought before it is compared
-- and kept ($51.50 / 250 = $0.206). If the paper's price is already by the foot (closer to the cost we have than the divided one is), it is
-- left alone. The words "[roll $51.50 ÷ 250 ft]" are added to the line so Approvals can show where the number came from.
-- Safe to run more than once.
CREATE OR REPLACE FUNCTION public._cost_per_foot(p_item bigint, p_cost numeric) RETURNS numeric
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE
    WHEN p_cost IS NULL OR p_cost <= 0 OR coalesce(i.unit_length, 0) <= 0 OR coalesce(i.unit_of_measure, '') !~* '^(per )?(foot|feet|ft)$' THEN NULL
    WHEN coalesce(i.unit_cost, 0) > 0 AND abs(ln(p_cost / i.unit_cost)) <= abs(ln((p_cost / i.unit_length) / i.unit_cost)) THEN NULL   -- the paper is already by the foot
    WHEN coalesce(i.unit_cost, 0) <= 0 AND p_cost < 5 THEN NULL
    ELSE round(p_cost / i.unit_length, 4) END
  FROM pricebook_items i WHERE i.id = p_item $f$;

CREATE OR REPLACE FUNCTION public._add_cost_update(p_sku text, p_supplier text, p_code text, p_desc text, p_cost numeric, p_ref text, p_date date)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE it pricebook_items; n int; v_foot numeric; v_cost numeric := p_cost; v_desc text := p_desc;
BEGIN
  SELECT * INTO it FROM pricebook_items WHERE sku = p_sku ORDER BY active DESC, id DESC LIMIT 1;
  IF it.id IS NULL THEN RETURN 'not in price book'; END IF;
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
REVOKE EXECUTE ON FUNCTION public._cost_per_foot(bigint, numeric) FROM PUBLIC, anon, authenticated;

-- the costs already waiting on by-the-foot items: put them by the foot too (once: a line that has the words is left alone)
UPDATE pricebook_cost_updates u SET new_cost = public._cost_per_foot(u.item_id, u.new_cost),
  description = left(coalesce(u.description, ''), 150) || ' [roll $' || trim(to_char(u.new_cost, 'FM999999990.00')) || ' ÷ ' || (SELECT trim(to_char(i.unit_length, 'FM999999990.##')) FROM pricebook_items i WHERE i.id = u.item_id) || ' ft]'
WHERE u.status = 'waiting' AND u.kind = 'cost' AND coalesce(u.description, '') NOT LIKE '%[roll $%' AND public._cost_per_foot(u.item_id, u.new_cost) IS NOT NULL;

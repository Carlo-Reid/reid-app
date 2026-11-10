-- Add one pricing (markup) rule from the new-item form on Auto update, when there is none for the item's type and cost (Carlo, Nov 9).
-- The new rule fills the gap the cost sits in: from the end of the rule below it (or $0) up to the start of the rule above it (or "and up").
CREATE OR REPLACE FUNCTION public.pb_rule_add(p_type text, p_cost numeric, p_pct numeric)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE lo numeric; hi numeric; nid bigint;
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the pricing rules. Ask an owner.'; END IF;
  IF p_type NOT IN ('service', 'material', 'equipment', 'security') THEN RAISE EXCEPTION 'Pick what kind of item it is first'; END IF;
  IF coalesce(p_cost, 0) <= 0 THEN RAISE EXCEPTION 'Type what it costs us first'; END IF;
  IF p_pct IS NULL OR p_pct < 0 OR p_pct > 1000 THEN RAISE EXCEPTION 'The percent must be a number from 0 to 1000'; END IF;
  IF public._pb_rule_price(p_type, p_cost) IS NOT NULL THEN RAISE EXCEPTION 'There is already a pricing rule for this'; END IF;
  SELECT coalesce(max(cost_to), 0) INTO lo FROM pricebook_markup_rules WHERE item_type = p_type AND cost_to <= p_cost;
  SELECT min(cost_from) INTO hi FROM pricebook_markup_rules WHERE item_type = p_type AND cost_from > p_cost;
  INSERT INTO pricebook_markup_rules (item_type, cost_from, cost_to, markup_pct) VALUES (p_type, lo, hi, p_pct) RETURNING id INTO nid;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('pricebook_markup_rules', nid, 'insert', public.current_app_user_id(), NULL, jsonb_build_object('item_type', p_type, 'cost_from', lo, 'cost_to', hi, 'markup_pct', p_pct, 'from', 'new-item form'));
  RETURN jsonb_build_object('cost_from', lo, 'cost_to', hi, 'markup_pct', p_pct, 'price', public._pb_rule_price(p_type, p_cost));
END $function$;
REVOKE EXECUTE ON FUNCTION public.pb_rule_add(text, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_rule_add(text, numeric, numeric) TO authenticated;
NOTIFY pgrst, 'reload schema';

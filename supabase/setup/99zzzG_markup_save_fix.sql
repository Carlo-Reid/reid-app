-- Markup rules and member prices: the save was refused ("UPDATE requires a WHERE clause"); say which rows
CREATE OR REPLACE FUNCTION public.save_pb_pricing(p jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o jsonb := public.pb_pricing();
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF coalesce((p ->> 'member_discount_pct')::numeric, 0) NOT BETWEEN 0 AND 90 THEN RAISE EXCEPTION 'The member discount must be between 0 and 90%%'; END IF;
  IF coalesce((p ->> 'round_to')::numeric, 0.01) NOT IN (0.01, 0.05, 0.25, 0.5, 1, 5) THEN RAISE EXCEPTION 'Round to 1 cent, 5 cents, 25 cents, 50 cents, $1 or $5'; END IF;
  UPDATE pricebook_settings SET
    member_discount_pct = coalesce((p ->> 'member_discount_pct')::numeric, 0),
    member_types = coalesce(ARRAY(SELECT jsonb_array_elements_text(p -> 'member_types')), '{}'),
    rule_tolerance_pct = coalesce((p ->> 'rule_tolerance_pct')::numeric, 5),
    round_to = coalesce((p ->> 'round_to')::numeric, 0.01),
    updated_at = now()
  WHERE id = 1;
  IF p ? 'rules' THEN
    DELETE FROM pricebook_markup_rules WHERE true;
    INSERT INTO pricebook_markup_rules (item_type, cost_from, cost_to, markup_pct)
    SELECT r ->> 'item_type', coalesce((r ->> 'cost_from')::numeric, 0), nullif(r ->> 'cost_to', '')::numeric, (r ->> 'markup_pct')::numeric
    FROM jsonb_array_elements(p -> 'rules') r
    WHERE nullif(r ->> 'markup_pct', '') IS NOT NULL;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('pricebook_settings', 1, 'update', public.current_app_user_id(), o, public.pb_pricing());
END $$;

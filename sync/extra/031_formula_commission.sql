-- Pricing formulas: a flat Commission $ per series, added at the very end (after the markup, the rounding and the
-- "then add"):  sell = round((cost + thermostat/coil + material + warranty + labour) ÷ (1 − GP%), to round_to) + adder + commission
-- Partner prices add it too. Changing it reprices the series (the same trigger as the other numbers). Safe to run more than once.
ALTER TABLE public.price_formulas ADD COLUMN IF NOT EXISTS commission numeric(10,2) NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public._formula_calc(p_formula bigint, p_cost numeric, p_gp numeric, p_addon_item bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH f AS (SELECT * FROM price_formulas WHERE id = p_formula),
  a AS (SELECT coalesce((SELECT unit_cost FROM pricebook_items WHERE id = coalesce(p_addon_item, (SELECT addon_item_id FROM f))), 0) AS addon),
  c AS (SELECT f.*, a.addon, coalesce(p_cost, 0) + a.addon AS equip, coalesce(p_cost, 0) + a.addon + f.material + f.warranty + f.labour AS sub,
               coalesce(p_cost, 0) + a.addon + f.material + f.warranty + f.labour + f.office AS sub2, coalesce(p_gp, f.gp_pct) AS gp FROM f, a)
  SELECT CASE WHEN p_cost IS NULL OR p_cost <= 0 THEN NULL ELSE jsonb_build_object(
    'addon', addon, 'equipment', equip, 'sub', sub, 'sub2', sub2, 'gp', gp, 'commission', commission,
    'price', round(sub2 / (1 - gp) / nullif(round_to, 0)) * round_to + adder + coalesce(commission, 0),
    'hsg', round(sub2 / nullif(hsg_factor, 0), 2), 'sales', round(sub2 / nullif(hsg_factor, 0) / nullif(sales_factor, 0), 2)) END
  FROM c
$$;
REVOKE EXECUTE ON FUNCTION public._formula_calc(bigint, numeric, numeric, bigint) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._formula_calc_partner(p_formula bigint, p_partner bigint, p_cost numeric, p_addon_item bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  WITH f AS (SELECT fp.*, pf.addon_item_id, pf.commission FROM price_formula_partners fp JOIN price_formulas pf ON pf.id = fp.formula_id
             WHERE fp.formula_id = p_formula AND fp.partner_id = p_partner),
  a AS (SELECT coalesce((SELECT unit_cost FROM pricebook_items WHERE id = coalesce(p_addon_item, (SELECT addon_item_id FROM f))), 0) AS addon),
  c AS (SELECT f.*, a.addon, coalesce(p_cost, 0) + a.addon + f.material + f.warranty + f.labour + f.office AS sub2 FROM f, a)
  SELECT CASE WHEN p_cost IS NULL OR p_cost <= 0 THEN NULL ELSE jsonb_build_object('addon', addon, 'sub2', sub2, 'gp', gp_pct,
    'price', round(sub2 / (1 - gp_pct) / nullif(round_to, 0)) * round_to + adder + coalesce(commission, 0)) END FROM c
$f$;
REVOKE EXECUTE ON FUNCTION public._formula_calc_partner(bigint, bigint, numeric, bigint) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.price_formula_list()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT public._can_formulas() THEN NULL ELSE coalesce(jsonb_agg(jsonb_build_object(
    'id', f.id, 'name', f.name, 'section', f.section, 'description', f.description,
    'addon_item_id', f.addon_item_id, 'addon_name', a.name, 'addon_cost', a.unit_cost,
    'material', f.material, 'warranty', f.warranty, 'labour', f.labour, 'office', f.office, 'gp_pct', f.gp_pct,
    'round_to', f.round_to, 'adder', f.adder, 'commission', f.commission, 'hsg_factor', f.hsg_factor, 'sales_factor', f.sales_factor, 'active', f.active,
    'items', (SELECT count(*) FROM pricebook_items p WHERE p.price_formula_id = f.id),
    'gp', (SELECT jsonb_build_object('avg', avg(g), 'min', min(g), 'max', max(g)) FROM (
             SELECT (p.unit_price - (public._formula_calc(f.id, p.unit_cost, p.formula_gp_pct, p.formula_addon_item_id) ->> 'sub2')::numeric) / nullif(p.unit_price, 0) AS g
             FROM pricebook_items p WHERE p.price_formula_id = f.id AND p.unit_price > 0 AND p.unit_cost > 0) x)
  ) ORDER BY f.sort_order, f.name), '[]') END
  FROM price_formulas f LEFT JOIN pricebook_items a ON a.id = f.addon_item_id
$$;

CREATE OR REPLACE FUNCTION public.save_price_formula(p_id bigint, p jsonb)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id bigint := p_id; o price_formulas;
BEGIN
  IF NOT (public.has_permission('pricebook.edit') AND public._can_formulas()) THEN RAISE EXCEPTION 'You need "Edit the price book" and "See what parts and equipment cost"'; END IF;
  IF v_id IS NULL THEN
    INSERT INTO price_formulas (name, section, updated_by) VALUES (btrim(p ->> 'name'), nullif(btrim(p ->> 'section'), ''), public.current_app_user_id()) RETURNING id INTO v_id;
  END IF;
  SELECT * INTO o FROM price_formulas WHERE id = v_id;
  UPDATE price_formulas SET
    name = coalesce(nullif(btrim(p ->> 'name'), ''), name),
    section = CASE WHEN p ? 'section' THEN nullif(btrim(p ->> 'section'), '') ELSE section END,
    description = CASE WHEN p ? 'description' THEN nullif(btrim(p ->> 'description'), '') ELSE description END,
    addon_item_id = CASE WHEN p ? 'addon_item_id' THEN nullif(p ->> 'addon_item_id', '')::bigint ELSE addon_item_id END,
    material = coalesce(nullif(p ->> 'material', '')::numeric, material),
    warranty = coalesce(nullif(p ->> 'warranty', '')::numeric, warranty),
    labour = coalesce(nullif(p ->> 'labour', '')::numeric, labour),
    office = coalesce(nullif(p ->> 'office', '')::numeric, office),
    gp_pct = coalesce(nullif(p ->> 'gp_pct', '')::numeric, gp_pct),
    round_to = coalesce(nullif(p ->> 'round_to', '')::numeric, round_to),
    adder = coalesce(nullif(p ->> 'adder', '')::numeric, adder),
    commission = CASE WHEN p ? 'commission' THEN coalesce(nullif(p ->> 'commission', '')::numeric, 0) ELSE commission END,
    hsg_factor = coalesce(nullif(p ->> 'hsg_factor', '')::numeric, hsg_factor),
    sales_factor = coalesce(nullif(p ->> 'sales_factor', '')::numeric, sales_factor),
    active = coalesce((p ->> 'active')::boolean, active),
    updated_at = now(), updated_by = public.current_app_user_id()
  WHERE id = v_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('price_formulas', v_id, CASE WHEN p_id IS NULL THEN 'insert' ELSE 'update' END, public.current_app_user_id(), to_jsonb(o), p);
  RETURN v_id;
END $$;
NOTIFY pgrst, 'reload schema';

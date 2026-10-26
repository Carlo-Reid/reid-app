-- Pricing formulas, Carlo's way (Oct 26):
--   total cost (equipment + stat + material + warranty + labour)
--   A = total ÷ (1 − GP%)                          e.g. ÷ 0.8
--   owner take home = A × owner %                  sub total = A + owner take home
--   sales commission = sub total × commission %    sub total 2 = sub total + commission
--   partner books only: partner fee = sub total 2 × partner fee %    sub total 3 = sub total 2 + fee
--   then round to the nearest $100 and add the adder ($90).
-- Safe to run more than once.
ALTER TABLE public.price_formulas ADD COLUMN IF NOT EXISTS owner_pct numeric(5,2) NOT NULL DEFAULT 0 CHECK (owner_pct >= 0 AND owner_pct < 200);
ALTER TABLE public.price_formula_partners ADD COLUMN IF NOT EXISTS partner_fee_pct numeric(5,2) NOT NULL DEFAULT 0 CHECK (partner_fee_pct >= 0 AND partner_fee_pct < 200);

CREATE OR REPLACE FUNCTION public._formula_calc(p_formula bigint, p_cost numeric, p_gp numeric, p_addon_item bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH f AS (SELECT * FROM price_formulas WHERE id = p_formula),
  a AS (SELECT coalesce((SELECT unit_cost FROM pricebook_items WHERE id = coalesce(p_addon_item, (SELECT addon_item_id FROM f))), 0) AS addon),
  c AS (SELECT f.*, a.addon, coalesce(p_cost, 0) + a.addon AS equip, coalesce(p_cost, 0) + a.addon + f.material + f.warranty + f.labour AS sub,
               coalesce(p_cost, 0) + a.addon + f.material + f.warranty + f.labour + f.office AS sub2, coalesce(p_gp, f.gp_pct) AS gp FROM f, a),
  s AS (SELECT c.*, sub2 / (1 - gp) AS marked FROM c),
  t AS (SELECT s.*, marked * coalesce(owner_pct, 0) / 100 AS owner FROM s),
  u AS (SELECT t.*, (marked + owner) * coalesce(commission_pct, 0) / 100 AS comm FROM t)
  SELECT CASE WHEN p_cost IS NULL OR p_cost <= 0 THEN NULL ELSE jsonb_build_object(
    'addon', addon, 'equipment', equip, 'sub', sub, 'sub2', sub2, 'gp', gp,
    'marked', round(marked, 2), 'owner', round(owner, 2), 'subtotal', round(marked + owner, 2), 'commission', round(comm, 2), 'subtotal2', round(marked + owner + comm, 2),
    'price', round((marked + owner + comm) / nullif(round_to, 0)) * round_to + adder + coalesce(commission, 0),
    'hsg', round(sub2 / nullif(hsg_factor, 0), 2), 'sales', round(sub2 / nullif(hsg_factor, 0) / nullif(sales_factor, 0), 2)) END
  FROM u
$$;
REVOKE EXECUTE ON FUNCTION public._formula_calc(bigint, numeric, numeric, bigint) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._formula_calc_partner(p_formula bigint, p_partner bigint, p_cost numeric, p_addon_item bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  WITH f AS (SELECT fp.*, pf.addon_item_id, pf.commission, pf.commission_pct, pf.owner_pct FROM price_formula_partners fp JOIN price_formulas pf ON pf.id = fp.formula_id
             WHERE fp.formula_id = p_formula AND fp.partner_id = p_partner),
  a AS (SELECT coalesce((SELECT unit_cost FROM pricebook_items WHERE id = coalesce(p_addon_item, (SELECT addon_item_id FROM f))), 0) AS addon),
  c AS (SELECT f.*, a.addon, coalesce(p_cost, 0) + a.addon + f.material + f.warranty + f.labour + f.office AS sub2 FROM f, a),
  s AS (SELECT c.*, sub2 / (1 - gp_pct) AS marked FROM c),
  t AS (SELECT s.*, marked * coalesce(owner_pct, 0) / 100 AS owner FROM s),
  u AS (SELECT t.*, (marked + owner) * coalesce(commission_pct, 0) / 100 AS comm FROM t),
  v AS (SELECT u.*, (marked + owner + comm) * coalesce(partner_fee_pct, 0) / 100 AS fee FROM u)
  SELECT CASE WHEN p_cost IS NULL OR p_cost <= 0 THEN NULL ELSE jsonb_build_object('addon', addon, 'sub2', sub2, 'gp', gp_pct,
    'marked', round(marked, 2), 'owner', round(owner, 2), 'commission', round(comm, 2), 'fee', round(fee, 2), 'subtotal3', round(marked + owner + comm + fee, 2),
    'price', round((marked + owner + comm + fee) / nullif(round_to, 0)) * round_to + adder + coalesce(commission, 0)) END FROM v
$f$;
REVOKE EXECUTE ON FUNCTION public._formula_calc_partner(bigint, bigint, numeric, bigint) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.price_formula_partner_list()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT CASE WHEN NOT public._can_formulas() THEN NULL ELSE coalesce(jsonb_agg(jsonb_build_object(
    'formula_id', fp.formula_id, 'partner_id', fp.partner_id, 'material', fp.material, 'warranty', fp.warranty, 'labour', fp.labour,
    'office', fp.office, 'gp_pct', fp.gp_pct, 'round_to', fp.round_to, 'adder', fp.adder, 'partner_fee_pct', fp.partner_fee_pct,
    'gp', (SELECT jsonb_build_object('min', min(g), 'max', max(g)) FROM (
             SELECT ((x ->> 'price')::numeric - (x ->> 'sub2')::numeric) / nullif((x ->> 'price')::numeric, 0) AS g
             FROM pricebook_items p, LATERAL (SELECT public._formula_calc_partner(fp.formula_id, fp.partner_id, p.unit_cost, p.formula_addon_item_id) AS x) z
             WHERE p.price_formula_id = fp.formula_id AND p.unit_cost > 0) y))), '[]') END
  FROM price_formula_partners fp
$f$;

CREATE OR REPLACE FUNCTION public.price_formula_partner_set(p_formula bigint, p_partner bigint, p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
DECLARE r price_formulas; n numeric;
BEGIN
  IF NOT (public.has_permission('pricebook.edit') AND public._can_formulas()) THEN RAISE EXCEPTION 'You need "Edit the price book" and "See what parts and equipment cost"'; END IF;
  IF p IS NULL THEN DELETE FROM price_formula_partners WHERE formula_id = p_formula AND partner_id = p_partner; RETURN; END IF;
  SELECT * INTO r FROM price_formulas WHERE id = p_formula; IF NOT FOUND THEN RAISE EXCEPTION 'That series no longer exists'; END IF;
  IF NOT EXISTS (SELECT 1 FROM partners WHERE id = p_partner) THEN RAISE EXCEPTION 'That partner no longer exists'; END IF;
  n := nullif(p ->> 'gp_pct', '')::numeric; IF n IS NOT NULL AND (n < 0 OR n >= 0.95) THEN RAISE EXCEPTION 'The gross profit has to be under 95%%'; END IF;
  INSERT INTO price_formula_partners AS t (formula_id, partner_id, material, warranty, labour, office, gp_pct, round_to, adder, partner_fee_pct, updated_by)
  VALUES (p_formula, p_partner,
    coalesce(nullif(p ->> 'material', '')::numeric, r.material), coalesce(nullif(p ->> 'warranty', '')::numeric, r.warranty),
    coalesce(nullif(p ->> 'labour', '')::numeric, r.labour), coalesce(nullif(p ->> 'office', '')::numeric, r.office),
    coalesce(n, r.gp_pct), coalesce(nullif(p ->> 'round_to', '')::numeric, r.round_to), coalesce(nullif(p ->> 'adder', '')::numeric, r.adder),
    coalesce(nullif(p ->> 'partner_fee_pct', '')::numeric, 0), public.current_app_user_id())
  ON CONFLICT (formula_id, partner_id) DO UPDATE SET
    material = coalesce(nullif(p ->> 'material', '')::numeric, t.material), warranty = coalesce(nullif(p ->> 'warranty', '')::numeric, t.warranty),
    labour = coalesce(nullif(p ->> 'labour', '')::numeric, t.labour), office = coalesce(nullif(p ->> 'office', '')::numeric, t.office),
    gp_pct = coalesce(n, t.gp_pct), round_to = coalesce(nullif(p ->> 'round_to', '')::numeric, t.round_to), adder = coalesce(nullif(p ->> 'adder', '')::numeric, t.adder),
    partner_fee_pct = coalesce(nullif(p ->> 'partner_fee_pct', '')::numeric, t.partner_fee_pct),
    updated_at = now(), updated_by = public.current_app_user_id();
END $f$;

CREATE OR REPLACE FUNCTION public.price_formula_list()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT public._can_formulas() THEN NULL ELSE coalesce(jsonb_agg(jsonb_build_object(
    'id', f.id, 'name', f.name, 'section', f.section, 'description', f.description,
    'addon_item_id', f.addon_item_id, 'addon_name', a.name, 'addon_cost', a.unit_cost,
    'material', f.material, 'warranty', f.warranty, 'labour', f.labour, 'office', f.office, 'gp_pct', f.gp_pct,
    'round_to', f.round_to, 'adder', f.adder, 'commission', f.commission, 'commission_pct', f.commission_pct, 'owner_pct', f.owner_pct, 'hsg_factor', f.hsg_factor, 'sales_factor', f.sales_factor, 'active', f.active,
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
    commission_pct = CASE WHEN p ? 'commission_pct' THEN coalesce(nullif(p ->> 'commission_pct', '')::numeric, 0) ELSE commission_pct END,
    owner_pct = CASE WHEN p ? 'owner_pct' THEN coalesce(nullif(p ->> 'owner_pct', '')::numeric, 0) ELSE owner_pct END,
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

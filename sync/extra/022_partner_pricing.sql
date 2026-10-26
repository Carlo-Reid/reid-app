-- Partner pricing: each pricing formula (series) can have its own numbers per partner (Costco, Rona, …), giving a partner
-- price for every model in the series. Each price book can be allowed to print partner books (e.g. Randall: Reid + Costco).
-- Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.price_formula_partners (
  formula_id bigint NOT NULL REFERENCES public.price_formulas(id) ON DELETE CASCADE,
  partner_id bigint NOT NULL REFERENCES public.partners(id) ON DELETE CASCADE,
  material numeric(10,2) NOT NULL DEFAULT 0,
  warranty numeric(10,2) NOT NULL DEFAULT 0,
  labour   numeric(10,2) NOT NULL DEFAULT 0,
  office   numeric(10,2) NOT NULL DEFAULT 0,
  gp_pct   numeric(6,4) NOT NULL DEFAULT 0.32 CHECK (gp_pct >= 0 AND gp_pct < 0.95),
  round_to numeric(10,2) NOT NULL DEFAULT 100,
  adder    numeric(10,2) NOT NULL DEFAULT 90,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by bigint,
  PRIMARY KEY (formula_id, partner_id));
ALTER TABLE public.price_formula_partners ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.price_formula_partners FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.price_book_partners (
  book_id bigint NOT NULL REFERENCES public.price_books(id) ON DELETE CASCADE,
  partner_id bigint NOT NULL REFERENCES public.partners(id) ON DELETE CASCADE,
  PRIMARY KEY (book_id, partner_id));
ALTER TABLE public.price_book_partners ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.price_book_partners FROM anon, authenticated;

-- one model's partner price (null when that series has no numbers for the partner, or no cost)
CREATE OR REPLACE FUNCTION public._formula_calc_partner(p_formula bigint, p_partner bigint, p_cost numeric, p_addon_item bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  WITH f AS (SELECT fp.*, pf.addon_item_id FROM price_formula_partners fp JOIN price_formulas pf ON pf.id = fp.formula_id
             WHERE fp.formula_id = p_formula AND fp.partner_id = p_partner),
  a AS (SELECT coalesce((SELECT unit_cost FROM pricebook_items WHERE id = coalesce(p_addon_item, (SELECT addon_item_id FROM f))), 0) AS addon),
  c AS (SELECT f.*, a.addon, coalesce(p_cost, 0) + a.addon + f.material + f.warranty + f.labour + f.office AS sub2 FROM f, a)
  SELECT CASE WHEN p_cost IS NULL OR p_cost <= 0 THEN NULL ELSE jsonb_build_object('addon', addon, 'sub2', sub2, 'gp', gp_pct,
    'price', round(sub2 / (1 - gp_pct) / nullif(round_to, 0)) * round_to + adder) END FROM c
$f$;
REVOKE EXECUTE ON FUNCTION public._formula_calc_partner(bigint, bigint, numeric, bigint) FROM PUBLIC, anon, authenticated;

-- all partner numbers, with the GP each partner's prices really make (Pricing control page)
CREATE OR REPLACE FUNCTION public.price_formula_partner_list()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT CASE WHEN NOT public._can_formulas() THEN NULL ELSE coalesce(jsonb_agg(jsonb_build_object(
    'formula_id', fp.formula_id, 'partner_id', fp.partner_id, 'material', fp.material, 'warranty', fp.warranty, 'labour', fp.labour,
    'office', fp.office, 'gp_pct', fp.gp_pct, 'round_to', fp.round_to, 'adder', fp.adder,
    'gp', (SELECT jsonb_build_object('min', min(g), 'max', max(g)) FROM (
             SELECT ((x ->> 'price')::numeric - (x ->> 'sub2')::numeric) / nullif((x ->> 'price')::numeric, 0) AS g
             FROM pricebook_items p, LATERAL (SELECT public._formula_calc_partner(fp.formula_id, fp.partner_id, p.unit_cost, p.formula_addon_item_id) AS x) z
             WHERE p.price_formula_id = fp.formula_id AND p.unit_cost > 0) y))), '[]') END
  FROM price_formula_partners fp
$f$;

-- set one series' numbers for one partner (missing numbers start from Reid's); p null = take the partner pricing off
CREATE OR REPLACE FUNCTION public.price_formula_partner_set(p_formula bigint, p_partner bigint, p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
DECLARE r price_formulas; n numeric;
BEGIN
  IF NOT (public.has_permission('pricebook.edit') AND public._can_formulas()) THEN RAISE EXCEPTION 'You need "Edit the price book" and "See what parts and equipment cost"'; END IF;
  IF p IS NULL THEN DELETE FROM price_formula_partners WHERE formula_id = p_formula AND partner_id = p_partner; RETURN; END IF;
  SELECT * INTO r FROM price_formulas WHERE id = p_formula; IF NOT FOUND THEN RAISE EXCEPTION 'That series no longer exists'; END IF;
  IF NOT EXISTS (SELECT 1 FROM partners WHERE id = p_partner) THEN RAISE EXCEPTION 'That partner no longer exists'; END IF;
  n := nullif(p ->> 'gp_pct', '')::numeric; IF n IS NOT NULL AND (n < 0 OR n >= 0.95) THEN RAISE EXCEPTION 'The gross profit has to be under 95%%'; END IF;
  INSERT INTO price_formula_partners AS t (formula_id, partner_id, material, warranty, labour, office, gp_pct, round_to, adder, updated_by)
  VALUES (p_formula, p_partner,
    coalesce(nullif(p ->> 'material', '')::numeric, r.material), coalesce(nullif(p ->> 'warranty', '')::numeric, r.warranty),
    coalesce(nullif(p ->> 'labour', '')::numeric, r.labour), coalesce(nullif(p ->> 'office', '')::numeric, r.office),
    coalesce(n, r.gp_pct), coalesce(nullif(p ->> 'round_to', '')::numeric, r.round_to), coalesce(nullif(p ->> 'adder', '')::numeric, r.adder),
    public.current_app_user_id())
  ON CONFLICT (formula_id, partner_id) DO UPDATE SET
    material = coalesce(nullif(p ->> 'material', '')::numeric, t.material), warranty = coalesce(nullif(p ->> 'warranty', '')::numeric, t.warranty),
    labour = coalesce(nullif(p ->> 'labour', '')::numeric, t.labour), office = coalesce(nullif(p ->> 'office', '')::numeric, t.office),
    gp_pct = coalesce(n, t.gp_pct), round_to = coalesce(nullif(p ->> 'round_to', '')::numeric, t.round_to), adder = coalesce(nullif(p ->> 'adder', '')::numeric, t.adder),
    updated_at = now(), updated_by = public.current_app_user_id();
END $f$;

-- which partner books each price book may print
CREATE OR REPLACE FUNCTION public.price_book_partner_list()
RETURNS TABLE (book_id bigint, partner_id bigint) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT book_id, partner_id FROM price_book_partners WHERE public._pb_full()
$f$;
CREATE OR REPLACE FUNCTION public.price_book_partners_set(p_book bigint, p_partners bigint[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT (public._pb_full() AND (public.has_permission('staff.manage') OR coalesce(public._is_owner(), false))) THEN RAISE EXCEPTION 'You need "Edit the price book" and "Manage staff" to set up price books'; END IF;
  DELETE FROM price_book_partners WHERE book_id = p_book AND NOT (partner_id = ANY (coalesce(p_partners, '{}')));
  INSERT INTO price_book_partners (book_id, partner_id) SELECT p_book, x FROM unnest(coalesce(p_partners, '{}')) x
    WHERE EXISTS (SELECT 1 FROM partners WHERE id = x) ON CONFLICT DO NOTHING;
END $f$;

-- the partner books the signed-in person can print: everyone with partner pricing for editors, otherwise what their price book allows
CREATE OR REPLACE FUNCTION public.my_price_partners()
RETURNS TABLE (id bigint, name text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT p.id, p.name::text FROM partners p
  WHERE EXISTS (SELECT 1 FROM price_formula_partners fp WHERE fp.partner_id = p.id)
    AND ((public.has_permission('pricebook.edit') AND public._can_formulas())
         OR EXISTS (SELECT 1 FROM price_book_partners bp JOIN app_users u ON u.price_book_id = bp.book_id
                    WHERE u.id = public.current_app_user_id() AND bp.partner_id = p.id))
  ORDER BY p.name
$f$;

-- partner prices for these items (only for a partner the person may print); items whose series has no partner numbers are left out
CREATE OR REPLACE FUNCTION public.pb_partner_prices(p_partner bigint, p_ids bigint[])
RETURNS TABLE (item_id bigint, price numeric) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.my_price_partners() m WHERE m.id = p_partner) THEN RAISE EXCEPTION 'You can''t print that partner''s book'; END IF;
  RETURN QUERY SELECT i.id, (public._formula_calc_partner(i.price_formula_id, p_partner, i.unit_cost, i.formula_addon_item_id) ->> 'price')::numeric
    FROM pricebook_items i WHERE i.id = ANY (p_ids) AND i.price_formula_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM price_formula_partners fp WHERE fp.formula_id = i.price_formula_id AND fp.partner_id = p_partner);
END $f$;

REVOKE EXECUTE ON FUNCTION public.price_formula_partner_list(), public.price_formula_partner_set(bigint, bigint, jsonb), public.price_book_partner_list(),
  public.price_book_partners_set(bigint, bigint[]), public.my_price_partners(), public.pb_partner_prices(bigint, bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.price_formula_partner_list(), public.price_formula_partner_set(bigint, bigint, jsonb), public.price_book_partner_list(),
  public.price_book_partners_set(bigint, bigint[]), public.my_price_partners(), public.pb_partner_prices(bigint, bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Labour hours on a part add to its sell price (Carlo, Nov 10: "when I add labor hours to this part it should only be used to increase
-- the sell price of the part, so if 1 hour of labor then add 120 dollars"). One number, the Standard labour rate for parts
-- (pricebook_settings.part_labour_rate, $120 an hour to start), set on the Pricing page under the Parts and Materials markup.
-- Rule price of a part = the markup rule's price for its cost + its Labour hours (pricebook_items.est_labour_hours) x that rate.
-- Only Parts ('service') and Materials: equipment and security hours are for booking lengths, not for the price.
-- No price is changed by this file: the "off the rule" lists and Update price show the new rule price, and a person presses the button.
-- Safe to run more than once.
ALTER TABLE public.pricebook_settings ADD COLUMN IF NOT EXISTS part_labour_rate numeric NOT NULL DEFAULT 120;

CREATE OR REPLACE FUNCTION public._pb_labour_add(p_type text, p_hours numeric) RETURNS numeric
 LANGUAGE sql STABLE SET search_path TO 'public' AS $f$
  SELECT CASE WHEN p_type IN ('service', 'material') AND coalesce(p_hours, 0) > 0
    THEN round(p_hours * coalesce((SELECT s.part_labour_rate FROM pricebook_settings s LIMIT 1), 0), 2) ELSE 0 END $f$;

CREATE OR REPLACE FUNCTION public._pb_rule_price_item(p_type text, p_cost numeric, p_hours numeric) RETURNS numeric
 LANGUAGE sql STABLE SET search_path TO 'public' AS $f$
  SELECT public._pb_rule_price(p_type, p_cost) + public._pb_labour_add(p_type, p_hours) $f$;

CREATE OR REPLACE FUNCTION public.set_part_labour_rate(p_rate numeric) RETURNS numeric
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_old numeric;
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF p_rate IS NULL OR p_rate < 0 OR p_rate > 1000 THEN RAISE EXCEPTION 'The labour rate must be between $0 and $1,000 an hour'; END IF;
  SELECT part_labour_rate INTO v_old FROM pricebook_settings WHERE id = 1;
  UPDATE pricebook_settings SET part_labour_rate = round(p_rate, 2), updated_at = now() WHERE id = 1;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('pricebook_settings', 1, 'update', public.current_app_user_id(), jsonb_build_object('part_labour_rate', v_old), jsonb_build_object('part_labour_rate', round(p_rate, 2)));
  RETURN round(p_rate, 2);
END $f$;
REVOKE EXECUTE ON FUNCTION public.set_part_labour_rate(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_part_labour_rate(numeric) TO authenticated;

-- the functions that use the rule price, as they stand: give them the labour too (each one only if it is not done yet)
DO $do$
DECLARE r record; d text; n text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('pb_pricing',          '''round_to'', s.round_to,',                                   '''round_to'', s.round_to, ''part_labour_rate'', s.part_labour_rate,'),
    ('pb_list',             'public._pb_rule_price(p.item_type, p.unit_cost) AS rule',      'public._pb_rule_price_item(p.item_type, p.unit_cost, p.est_labour_hours) AS rule'),
    ('pb_apply_rule',       'public._pb_rule_price(item_type, unit_cost)',                  'public._pb_rule_price_item(item_type, unit_cost, est_labour_hours)'),
    ('pb_cost_updates',     'public._pb_rule_price(p.item_type, u.new_cost)',               'public._pb_rule_price_item(p.item_type, u.new_cost, p.est_labour_hours)'),
    ('decide_cost_updates', 'p.unit_price AS cur_price, p.item_type',                       'p.unit_price AS cur_price, p.est_labour_hours AS lab_hours, p.item_type'),
    ('decide_cost_updates', 'public._pb_rule_price(u.item_type, u.new_cost)',               'public._pb_rule_price_item(u.item_type, u.new_cost, u.lab_hours)')
  ) v(fn, a, b) LOOP
    SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = r.fn;
    IF d IS NULL THEN RAISE NOTICE '%: not found', r.fn; CONTINUE; END IF;
    IF position(r.b in d) > 0 THEN CONTINUE; END IF;
    IF position(r.a in d) = 0 THEN RAISE NOTICE '%: the words to change were not found', r.fn; CONTINUE; END IF;
    EXECUTE replace(d, r.a, r.b);
  END LOOP;
END $do$;

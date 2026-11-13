-- Vista rental rates: Vista's own tables (by supplier: each tank or system, each monthly rental rate, and the allowance
-- Vista gives for the install and the equipment at that rate), which price book item is which Vista tank, and the rate
-- picked on a proposal or a Vista job. (Carlo, Nov 13, 2026: "it takes our tanks, sorts by suppliers and shows you the
-- rental options. I want to build this into the system so when it's a rental tank it shows the rental price and I have
-- a way to adjust it".)
-- The numbers themselves are Vista's price list: they are loaded straight into the database (Nov 13, from Carlo's file; later
-- from the Vista rental rates page, "Load Vista's Excel file"), never written in this file, because this repository is public.

-- one row = one tank (or system) at one monthly rate
CREATE TABLE IF NOT EXISTS public.vista_rental_rates (
  id bigserial PRIMARY KEY,
  supplier text NOT NULL,            -- Boone, TML, Wolseley, or HVAC (Vista's HVAC table has no supplier)
  cat text NOT NULL,                 -- the sheet: Standard WH, Tankless, Combi & Boiler …
  grp text NOT NULL,                 -- the kind: Conventional Vent Hot Water Tanks (CV) - USG …
  model text NOT NULL,               -- 40G (NG), RX160iN …
  descr text NOT NULL DEFAULT '',    -- 160K BTU …
  rate numeric(9,2) NOT NULL CHECK (rate > 0),             -- a month, before tax
  allowance numeric(11,2) NOT NULL CHECK (allowance >= 0), -- install + equipment
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by bigint,
  UNIQUE (supplier, cat, grp, model, rate));
ALTER TABLE public.vista_rental_rates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vista_rental_rates FROM PUBLIC, anon, authenticated;

-- which Vista tank a price book item is, and the monthly rate we usually use for it (optional)
CREATE TABLE IF NOT EXISTS public.vista_rental_links (
  item_id bigint PRIMARY KEY,
  supplier text NOT NULL, cat text NOT NULL, grp text NOT NULL, model text NOT NULL,
  rate numeric(9,2),
  set_by bigint, set_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.vista_rental_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vista_rental_links FROM PUBLIC, anon, authenticated;

-- the rate picked on a proposal (for one of its items) or on a Vista job: a copy of the numbers on that day,
-- so a later change to Vista's table does not change what was quoted
CREATE TABLE IF NOT EXISTS public.vista_rental_picks (
  id bigserial PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('estimate', 'job')),
  ref_id bigint NOT NULL, item_id bigint NOT NULL DEFAULT 0,
  supplier text NOT NULL, cat text NOT NULL, grp text NOT NULL, model text NOT NULL, descr text NOT NULL DEFAULT '',
  rate numeric(9,2) NOT NULL, allowance numeric(11,2) NOT NULL,
  set_by bigint, set_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (kind, ref_id, item_id));
ALTER TABLE public.vista_rental_picks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vista_rental_picks FROM PUBLIC, anon, authenticated;

-- everything the app needs in one answer: every tank with its rates, and the price book items that are Vista tanks
CREATE OR REPLACE FUNCTION public.vista_rates() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE jsonb_build_object(
    'can_edit', public.current_staff_role() = 'owner',
    'can_link', public.current_staff_role() = 'owner' OR public.has_permission('pricebook.edit'),
    'updated', (SELECT max(updated_at) FROM vista_rental_rates),
    'tanks', coalesce((SELECT jsonb_agg(t ORDER BY t ->> 's', t ->> 'c', t ->> 'g', (t ->> 'lo')::numeric, t ->> 'm') FROM (
        SELECT jsonb_build_object('s', supplier, 'c', cat, 'g', grp, 'm', model, 'd', max(descr), 'lo', min(rate),
                 'r', jsonb_agg(jsonb_build_array(id, rate, allowance) ORDER BY rate)) AS t
          FROM vista_rental_rates GROUP BY supplier, cat, grp, model) x), '[]'::jsonb),
    'links', coalesce((SELECT jsonb_object_agg(item_id::text, jsonb_build_object('s', supplier, 'c', cat, 'g', grp, 'm', model, 'rate', rate)) FROM vista_rental_links), '{}'::jsonb)) END
$function$;

-- owners change the table: p = [{op:'set', s, c, g, m, d, rate, allowance}, {op:'del', id}, {op:'del_tank', s, c, g, m}]
CREATE OR REPLACE FUNCTION public.vista_rates_save(p jsonb) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE o jsonb; n integer := 0; v_me bigint := public.current_app_user_id(); v_rate numeric; v_al numeric;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only an owner can change Vista''s rental rates'; END IF;
  IF jsonb_typeof(p) <> 'array' OR jsonb_array_length(p) > 5000 THEN RAISE EXCEPTION 'That is not a list of changes I can read'; END IF;
  FOR o IN SELECT * FROM jsonb_array_elements(p) LOOP
    IF o ->> 'op' = 'del' THEN
      DELETE FROM vista_rental_rates WHERE id = (o ->> 'id')::bigint; n := n + 1;
    ELSIF o ->> 'op' = 'del_tank' THEN
      DELETE FROM vista_rental_rates WHERE supplier = o ->> 's' AND cat = o ->> 'c' AND grp = o ->> 'g' AND model = o ->> 'm'; n := n + 1;
    ELSIF o ->> 'op' = 'set' THEN
      v_rate := round((o ->> 'rate')::numeric, 2); v_al := round((o ->> 'allowance')::numeric, 2);
      IF v_rate IS NULL OR v_rate <= 0 OR v_rate > 100000 OR v_al IS NULL OR v_al < 0 OR v_al > 10000000 THEN RAISE EXCEPTION 'A monthly rate or an allowance is not a number I can use'; END IF;
      IF coalesce(btrim(o ->> 's'), '') = '' OR coalesce(btrim(o ->> 'c'), '') = '' OR coalesce(btrim(o ->> 'g'), '') = '' OR coalesce(btrim(o ->> 'm'), '') = '' THEN RAISE EXCEPTION 'The supplier, the kind and the tank''s name are all needed'; END IF;
      INSERT INTO vista_rental_rates (supplier, cat, grp, model, descr, rate, allowance, updated_by)
      VALUES (left(btrim(o ->> 's'), 60), left(btrim(o ->> 'c'), 80), left(btrim(o ->> 'g'), 160), left(btrim(o ->> 'm'), 80), left(coalesce(btrim(o ->> 'd'), ''), 160), v_rate, v_al, v_me)
      ON CONFLICT (supplier, cat, grp, model, rate) DO UPDATE SET allowance = EXCLUDED.allowance, updated_at = now(), updated_by = v_me,
        descr = CASE WHEN o ? 'd' THEN EXCLUDED.descr ELSE vista_rental_rates.descr END;
      n := n + 1;
    END IF;
  END LOOP;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('vista_rental_rates', 0, 'update', v_me, jsonb_build_object('changes', n, 'what', CASE WHEN jsonb_array_length(p) <= 40 THEN p ELSE to_jsonb('many'::text) END));
  RETURN n;
END $function$;

-- owners load Vista's whole list from its Excel file: every supplier named in the rows is replaced by the rows given
-- p_rows = [[supplier, cat, grp, model, descr, rate, allowance], …]
CREATE OR REPLACE FUNCTION public.vista_rates_load(p_rows jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_me bigint := public.current_app_user_id(); v_del integer; v_ins integer;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only an owner can load Vista''s rental rates'; END IF;
  IF jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) < 1 OR jsonb_array_length(p_rows) > 30000 THEN RAISE EXCEPTION 'I could not read any rates in that file'; END IF;
  CREATE TEMP TABLE _vr ON COMMIT DROP AS
    SELECT left(btrim(r ->> 0), 60) s, left(btrim(r ->> 1), 80) c, left(btrim(r ->> 2), 160) g, left(btrim(r ->> 3), 80) m, left(coalesce(btrim(r ->> 4), ''), 160) d,
           round((r ->> 5)::numeric, 2) rate, round((r ->> 6)::numeric, 2) al
      FROM jsonb_array_elements(p_rows) r;
  IF EXISTS (SELECT 1 FROM _vr WHERE coalesce(s, '') = '' OR coalesce(c, '') = '' OR coalesce(g, '') = '' OR coalesce(m, '') = '' OR rate IS NULL OR rate <= 0 OR al IS NULL OR al < 0) THEN
    RAISE EXCEPTION 'Some lines of that file have no name, no monthly rate or no allowance. Nothing was changed.'; END IF;
  DELETE FROM vista_rental_rates WHERE supplier IN (SELECT DISTINCT s FROM _vr); GET DIAGNOSTICS v_del = ROW_COUNT;
  INSERT INTO vista_rental_rates (supplier, cat, grp, model, descr, rate, allowance, updated_by)
    SELECT s, c, g, m, max(d), rate, max(al), v_me FROM _vr GROUP BY s, c, g, m, rate; GET DIAGNOSTICS v_ins = ROW_COUNT;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('vista_rental_rates', 0, 'insert', v_me, jsonb_build_object('loaded', v_ins, 'replaced', v_del, 'suppliers', (SELECT jsonb_agg(DISTINCT s) FROM _vr)));
  RETURN jsonb_build_object('loaded', v_ins, 'replaced', v_del, 'suppliers', (SELECT jsonb_agg(DISTINCT s) FROM _vr));
END $function$;

-- which Vista tank a price book item is (people who can change the price book). p null = it is not a rental tank.
CREATE OR REPLACE FUNCTION public.vista_link_set(p_item bigint, p jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT (public.current_staff_role() = 'owner' OR public.has_permission('pricebook.edit')) THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pricebook_items WHERE id = p_item) THEN RAISE EXCEPTION 'That price book item no longer exists'; END IF;
  IF p IS NULL OR p = 'null'::jsonb THEN
    DELETE FROM vista_rental_links WHERE item_id = p_item;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM vista_rental_rates WHERE supplier = p ->> 's' AND cat = p ->> 'c' AND grp = p ->> 'g' AND model = p ->> 'm') THEN RAISE EXCEPTION 'That tank is not in Vista''s table any more'; END IF;
    INSERT INTO vista_rental_links (item_id, supplier, cat, grp, model, rate, set_by)
    VALUES (p_item, p ->> 's', p ->> 'c', p ->> 'g', p ->> 'm', nullif(p ->> 'rate', '')::numeric, v_me)
    ON CONFLICT (item_id) DO UPDATE SET supplier = EXCLUDED.supplier, cat = EXCLUDED.cat, grp = EXCLUDED.grp, model = EXCLUDED.model, rate = EXCLUDED.rate, set_by = v_me, set_at = now();
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('vista_rental_links', p_item, 'update', v_me, coalesce(p, '{}'::jsonb));
END $function$;

-- the rates picked on a proposal (one for each of its items) or on a job
CREATE OR REPLACE FUNCTION public.vista_picks(p_kind text, p_ref bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('item', item_id, 's', supplier, 'c', cat, 'g', grp, 'm', model, 'd', descr, 'rate', rate, 'allowance', allowance, 'at', set_at) ORDER BY id)
      FROM vista_rental_picks WHERE kind = p_kind AND ref_id = p_ref), '[]'::jsonb) END
$function$;

-- pick a rate (a row of Vista's table) for a proposal's item or for a job; p_rate_id null takes the pick off
CREATE OR REPLACE FUNCTION public.vista_pick_set(p_kind text, p_ref bigint, p_item bigint, p_rate_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_me bigint := public.current_app_user_id(); r vista_rental_rates; v_item bigint := coalesce(p_item, 0);
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  IF p_kind NOT IN ('estimate', 'job') THEN RAISE EXCEPTION 'Unknown kind'; END IF;
  IF p_kind = 'estimate' AND NOT EXISTS (SELECT 1 FROM estimates WHERE id = p_ref) THEN RAISE EXCEPTION 'That proposal no longer exists'; END IF;
  IF p_kind = 'job' AND NOT EXISTS (SELECT 1 FROM jobs WHERE id = p_ref) THEN RAISE EXCEPTION 'That job no longer exists'; END IF;
  IF p_rate_id IS NULL THEN
    DELETE FROM vista_rental_picks WHERE kind = p_kind AND ref_id = p_ref AND item_id = v_item; RETURN NULL;
  END IF;
  SELECT * INTO r FROM vista_rental_rates WHERE id = p_rate_id;
  IF r.id IS NULL THEN RAISE EXCEPTION 'That rate is not in Vista''s table any more. Open the list again and pick one.'; END IF;
  INSERT INTO vista_rental_picks (kind, ref_id, item_id, supplier, cat, grp, model, descr, rate, allowance, set_by)
  VALUES (p_kind, p_ref, v_item, r.supplier, r.cat, r.grp, r.model, r.descr, r.rate, r.allowance, v_me)
  ON CONFLICT (kind, ref_id, item_id) DO UPDATE SET supplier = EXCLUDED.supplier, cat = EXCLUDED.cat, grp = EXCLUDED.grp, model = EXCLUDED.model,
    descr = EXCLUDED.descr, rate = EXCLUDED.rate, allowance = EXCLUDED.allowance, set_by = v_me, set_at = now();
  IF p_kind = 'job' THEN
    INSERT INTO notes (entity_type, entity_id, body, author_user_id, source)
    VALUES ('job', p_ref, 'Vista rental price: ' || r.model || CASE WHEN r.descr <> '' THEN ' (' || r.descr || ')' ELSE '' END || ', ' || r.grp
      || CASE WHEN r.supplier <> 'HVAC' THEN ', from ' || r.supplier ELSE '' END || ': $' || to_char(r.rate, 'FM999990.00') || ' a month, allowance $' || to_char(r.allowance, 'FM999,999,990.00') || '.', v_me, 'booking');
  END IF;
  RETURN jsonb_build_object('s', r.supplier, 'c', r.cat, 'g', r.grp, 'm', r.model, 'd', r.descr, 'rate', r.rate, 'allowance', r.allowance);
END $function$;

REVOKE EXECUTE ON FUNCTION public.vista_rates(), public.vista_rates_save(jsonb), public.vista_rates_load(jsonb), public.vista_link_set(bigint, jsonb),
  public.vista_picks(text, bigint), public.vista_pick_set(text, bigint, bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vista_rates(), public.vista_rates_save(jsonb), public.vista_rates_load(jsonb), public.vista_link_set(bigint, jsonb),
  public.vista_picks(text, bigint), public.vista_pick_set(text, bigint, bigint, bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

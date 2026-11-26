-- A line number (001, 002, 44) read off a supplier's paper is never a part number (Carlo, Nov 25, 2026:
-- "John Wood Gas Valve Control For Envirosense Units 100283608 · Goodman code 001 the system is trying to
-- match it with the wrong item in the price book").
-- What happened: a paper's line number "001" was sent as the part's code; Boone's own part number for the
-- gas valve had been overwritten with "001" when an earlier cost line was approved; and the match by a
-- supplier's own part number looked at every supplier, so a Goodman line "001" found Boone's "001".
-- Now:
--   1. a code of 1 to 3 digits only is a line number: it is not matched by code and no new item is made from it
--      (a line the browser already tied to an item by item_sku still goes through);
--   2. a supplier's own part number is only looked up for that same supplier;
--   3. approving a cost line never saves a line number as the supplier's part number;
--   4. the line-number part numbers already saved are put right (Boone's gas valve gets 100283608 back).

CREATE OR REPLACE FUNCTION public._is_line_no(p text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT coalesce(btrim(p), '') ~ '^[0-9]{1,3}$' $$;

CREATE OR REPLACE FUNCTION public.import_supplier_lines(p_supplier text, p_ref text, p_date date, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE l jsonb; v_sku text; r text; out jsonb := '{}'::jsonb; v_lines jsonb := '[]'::jsonb; v_sid bigint := public._supplier_by_name(p_supplier); c text; ln boolean;
BEGIN
  IF NOT public._can_approve_costs() THEN
    RAISE EXCEPTION 'You need "Edit the price book" and "See what parts and equipment cost" to import supplier invoices';
  END IF;
  IF coalesce(btrim(p_supplier), '') = '' OR coalesce(btrim(p_ref), '') = '' THEN RAISE EXCEPTION 'The supplier and invoice number are needed'; END IF;
  FOR l IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    CONTINUE WHEN coalesce(btrim(l ->> 'code'), '') = '' OR (l ->> 'cost') IS NULL OR (l ->> 'cost')::numeric < 0;
    c := btrim(l ->> 'code'); v_sku := NULL; ln := public._is_line_no(c);
    IF nullif(btrim(l ->> 'item_sku'), '') IS NOT NULL THEN
      SELECT sku INTO v_sku FROM pricebook_items WHERE sku = btrim(l ->> 'item_sku') AND NOT pending_new LIMIT 1;
    END IF;
    IF v_sku IS NULL AND NOT ln THEN
      SELECT sku INTO v_sku FROM pricebook_items
      WHERE NOT pending_new AND (upper(sku) = upper(c) OR public._sku_key(sku) = public._sku_key(c))
      ORDER BY upper(sku) = upper(c) DESC, active DESC, id DESC LIMIT 1;
    END IF;
    IF v_sku IS NULL AND NOT ln AND v_sid IS NOT NULL THEN
      SELECT i.sku INTO v_sku FROM supplier_items si JOIN pricebook_items i ON i.id = si.item_id
      WHERE si.supplier_id = v_sid AND upper(si.supplier_sku) = upper(c) AND NOT i.pending_new ORDER BY i.active DESC LIMIT 1;
    END IF;
    IF v_sku IS NULL AND NOT ln AND length(c) >= 5 THEN
      SELECT sku INTO v_sku FROM pricebook_items WHERE NOT pending_new AND upper(model_number) = upper(c) ORDER BY active DESC, id DESC LIMIT 1;
    END IF;
    IF v_sku IS NULL AND NOT ln THEN
      SELECT sku INTO v_sku FROM pricebook_items WHERE pending_new AND upper(sku) = upper(c) LIMIT 1;
    END IF;
    IF v_sku IS NOT NULL THEN
      r := public._add_cost_update(v_sku, p_supplier, CASE WHEN ln THEN NULL ELSE c END, left(l ->> 'description', 200), round((l ->> 'cost')::numeric, 4), p_ref, p_date);
    ELSIF ln THEN
      r := 'not matched';
    ELSIF coalesce((l ->> 'new_ok')::boolean, true) THEN
      r := public._add_new_item(c, left(coalesce(nullif(btrim(l ->> 'description'), ''), c), 200), 'material',
                                p_supplier, round((l ->> 'cost')::numeric, 4), p_ref, p_date);
    ELSE
      r := 'not matched';
    END IF;
    out := jsonb_set(out, ARRAY[r], to_jsonb(coalesce((out ->> r)::int, 0) + 1));
    v_lines := v_lines || jsonb_build_object('code', c, 'result', r);
  END LOOP;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pricebook_cost_updates', 0, 'insert', public.current_app_user_id(),
          jsonb_build_object('change', 'imported ' || p_supplier || ' ' || p_ref, 'results', out));
  RETURN jsonb_build_object('counts', out, 'lines', v_lines);
END $function$;

CREATE OR REPLACE FUNCTION public._cost_update_to_supplier()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE sid bigint; code text;
BEGIN
  IF NEW.status = 'approved' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'approved') AND NEW.item_id IS NOT NULL THEN
    sid := public._supplier_by_name(NEW.supplier);
    code := CASE WHEN public._is_line_no(NEW.supplier_code) THEN NULL ELSE nullif(btrim(NEW.supplier_code), '') END;
    IF sid IS NOT NULL THEN
      INSERT INTO supplier_items (supplier_id, item_id, supplier_sku, cost, is_preferred, price_date)
      VALUES (sid, NEW.item_id, code, NEW.new_cost,
              NOT EXISTS (SELECT 1 FROM supplier_items x WHERE x.item_id = NEW.item_id), coalesce(NEW.doc_date, current_date))
      ON CONFLICT (supplier_id, item_id) DO UPDATE SET cost = coalesce(EXCLUDED.cost, supplier_items.cost), supplier_sku = coalesce(EXCLUDED.supplier_sku, supplier_items.supplier_sku),
        price_date = EXCLUDED.price_date, updated_at = now();
    END IF;
  END IF;
  RETURN NEW;
END $function$;

-- the line numbers already saved as a supplier's part number (leading zero, 1 to 3 digits: 001, 005, 017)
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT si.*, i.sku FROM supplier_items si JOIN pricebook_items i ON i.id = si.item_id
           WHERE si.supplier_sku ~ '^0[0-9]{1,2}$' LOOP
    INSERT INTO audit_log (table_name, row_id, action, new_values)
    VALUES ('supplier_items', r.id, 'update', jsonb_build_object('why', 'a line number was saved as the supplier''s part number', 'was', r.supplier_sku));
    -- the part's own number is the supplier's number when the item is that supplier's (Boone's gas valve: 100283608)
    UPDATE supplier_items SET supplier_sku = CASE WHEN r.sku ~ '^[0-9]{6,}$' THEN r.sku ELSE NULL END, updated_at = now() WHERE id = r.id;
  END LOOP;
END $$;

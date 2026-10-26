-- =====================================================================
-- Security parts: a new price book item type ('security'), shown as "Security" next to Parts.
-- Works like Parts everywhere: Price book (Security only button, Show list, Move to), markup sheet, member prices,
-- print books, estimates and invoices, and accounting (starts with the same accounts as Parts).
-- Safe to run more than once.
-- =====================================================================
-- 1. the item type lists the database allows
DO $$ DECLARE c record; BEGIN
  FOR c IN SELECT conname FROM pg_constraint WHERE conrelid = 'public.pricebook_items'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) ILIKE '%item_type = ANY%'
              AND pg_get_constraintdef(oid) NOT ILIKE '%security%' LOOP
    EXECUTE format('ALTER TABLE public.pricebook_items DROP CONSTRAINT %I', c.conname);
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.pricebook_items'::regclass AND conname = 'pricebook_items_item_type_check2') THEN
    ALTER TABLE public.pricebook_items ADD CONSTRAINT pricebook_items_item_type_check2
      CHECK (item_type IN ('service','material','equipment','warranty','plan','fee','labour','monitoring','security'));
  END IF;
  FOR c IN SELECT conname FROM pg_constraint WHERE conrelid = 'public.pricebook_markup_rules'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) ILIKE '%item_type = ANY%'
              AND pg_get_constraintdef(oid) NOT ILIKE '%security%' LOOP
    EXECUTE format('ALTER TABLE public.pricebook_markup_rules DROP CONSTRAINT %I', c.conname);
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.pricebook_markup_rules'::regclass AND conname = 'pricebook_markup_rules_item_type_check2') THEN
    ALTER TABLE public.pricebook_markup_rules ADD CONSTRAINT pricebook_markup_rules_item_type_check2
      CHECK (item_type IN ('material', 'equipment', 'service', 'fee', 'labour', 'security'));
  END IF;
END $$;

-- 2. accounting: Security starts with the same accounts as Parts (change them on the Accounting page)
INSERT INTO public.gl_defaults (item_type, income, cogs, inventory)
SELECT 'security', income, cogs, inventory FROM public.gl_defaults WHERE item_type = 'service'
ON CONFLICT (item_type) DO NOTHING;

-- 3. adding or changing an item can use Security
CREATE OR REPLACE FUNCTION public.save_pb_item(p_id bigint, p jsonb)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o pricebook_items; n pricebook_items; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF p ? 'name' AND nullif(btrim(p ->> 'name'), '') IS NULL THEN RAISE EXCEPTION 'The item needs a name'; END IF;
  IF p ? 'unit_price' AND (p ->> 'unit_price')::numeric < 0 THEN RAISE EXCEPTION 'The price can''t be below zero'; END IF;
  IF p ? 'unit_cost' AND (p ->> 'unit_cost')::numeric < 0 THEN RAISE EXCEPTION 'The cost can''t be below zero'; END IF;
  IF nullif(p ->> 'member_price', '') IS NOT NULL AND (p ->> 'member_price')::numeric < 0 THEN RAISE EXCEPTION 'The member price can''t be below zero'; END IF;
  IF p ? 'item_type' AND (p ->> 'item_type') NOT IN ('service', 'material', 'equipment', 'fee', 'labour', 'security') THEN RAISE EXCEPTION 'Pick parts, materials, equipment, security, fees or labour'; END IF;
  IF nullif(btrim(p ->> 'sku'), '') IS NOT NULL AND EXISTS (SELECT 1 FROM pricebook_items WHERE lower(sku) = lower(btrim(p ->> 'sku')) AND id IS DISTINCT FROM p_id AND active) THEN
    RAISE EXCEPTION 'Another item already uses the code %', btrim(p ->> 'sku');
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO pricebook_items (item_type, sku, name, description, unit_of_measure, unit_price, unit_cost, taxable, est_labour_hours, preferred_supplier_id,
                                 member_price, manufacturer, model_number)
    VALUES (coalesce(p ->> 'item_type', 'material'), coalesce(nullif(btrim(p ->> 'sku'), ''), 'NEW-' || nextval(pg_get_serial_sequence('pricebook_items', 'id'))),
            btrim(p ->> 'name'), nullif(btrim(p ->> 'description'), ''), coalesce(nullif(btrim(p ->> 'unit_of_measure'), ''), 'each'),
            coalesce((p ->> 'unit_price')::numeric, 0), coalesce((p ->> 'unit_cost')::numeric, 0), coalesce((p ->> 'taxable')::boolean, true),
            nullif(p ->> 'est_labour_hours', '')::numeric, nullif(p ->> 'preferred_supplier_id', '')::bigint,
            nullif(p ->> 'member_price', '')::numeric, nullif(btrim(p ->> 'manufacturer'), ''), nullif(btrim(p ->> 'model'), ''))
    RETURNING * INTO n;
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('pricebook_items', n.id, 'insert', v_me, to_jsonb(n));
    RETURN n.id;
  END IF;
  SELECT * INTO o FROM pricebook_items WHERE id = p_id;
  IF o.id IS NULL THEN RAISE EXCEPTION 'That item no longer exists'; END IF;
  UPDATE pricebook_items SET
    item_type = coalesce(p ->> 'item_type', item_type),
    sku = CASE WHEN nullif(btrim(p ->> 'sku'), '') IS NOT NULL THEN btrim(p ->> 'sku') ELSE sku END,
    name = coalesce(nullif(btrim(p ->> 'name'), ''), name),
    description = CASE WHEN p ? 'description' THEN nullif(btrim(p ->> 'description'), '') ELSE description END,
    unit_of_measure = coalesce(nullif(btrim(p ->> 'unit_of_measure'), ''), unit_of_measure),
    unit_price = coalesce(nullif(p ->> 'unit_price', '')::numeric, unit_price),
    unit_cost = coalesce(nullif(p ->> 'unit_cost', '')::numeric, unit_cost),
    taxable = coalesce((p ->> 'taxable')::boolean, taxable),
    active = coalesce((p ->> 'active')::boolean, active),
    est_labour_hours = CASE WHEN p ? 'est_labour_hours' THEN nullif(p ->> 'est_labour_hours', '')::numeric ELSE est_labour_hours END,
    preferred_supplier_id = CASE WHEN p ? 'preferred_supplier_id' THEN nullif(p ->> 'preferred_supplier_id', '')::bigint ELSE preferred_supplier_id END,
    member_price = CASE WHEN p ? 'member_price' THEN nullif(p ->> 'member_price', '')::numeric ELSE member_price END,
    manufacturer = CASE WHEN p ? 'manufacturer' THEN nullif(btrim(p ->> 'manufacturer'), '') ELSE manufacturer END,
    model_number = CASE WHEN p ? 'model' THEN nullif(btrim(p ->> 'model'), '') ELSE model_number END
  WHERE id = p_id RETURNING * INTO n;
  IF to_jsonb(o) - 'updated_at' IS DISTINCT FROM to_jsonb(n) - 'updated_at' THEN
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values) VALUES ('pricebook_items', p_id, 'update', v_me, to_jsonb(o), to_jsonb(n));
  END IF;
  RETURN p_id;
END $$;

-- 4. Move to… can move items to Security
CREATE OR REPLACE FUNCTION public.pb_set_items_type(p_ids bigint[], p_type text)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n int;
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF p_type NOT IN ('material', 'equipment', 'service', 'fee', 'labour', 'security') THEN RAISE EXCEPTION 'Pick Equipment, Materials, Parts, Security, Fees or Labour'; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  SELECT 'pricebook_items', id, 'update', public.current_app_user_id(), jsonb_build_object('item_type', item_type), jsonb_build_object('item_type', p_type)
  FROM pricebook_items WHERE id = ANY (p_ids) AND item_type <> p_type;
  UPDATE pricebook_items SET item_type = p_type, updated_at = now() WHERE id = ANY (p_ids) AND item_type <> p_type;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

NOTIFY pgrst, 'reload schema';

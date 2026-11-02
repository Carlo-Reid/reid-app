-- POs: a line with a minus or 0 quantity (a returned or back-ordered item) broke the "quantity above 0" rule when a PO was made
-- from a supplier invoice or saved on the PO page. A minus quantity now moves its minus to the cost; 0 with a cost counts as 1.
CREATE OR REPLACE FUNCTION public.supplier_invoice_make_po(p_invoice bigint, p_lines jsonb, p_what text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i supplier_invoices; v jsonb; v_po bigint; x jsonb; n int := 0; q numeric; c numeric;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  SELECT * INTO i FROM supplier_invoices WHERE id = p_invoice;
  IF i.id IS NULL THEN RAISE EXCEPTION 'That invoice isn''t in the app'; END IF;
  IF i.purchase_order_id IS NOT NULL OR public._sinv_po(i) IS NOT NULL THEN RAISE EXCEPTION 'This invoice already has a PO'; END IF;
  IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN RAISE EXCEPTION 'Add at least one line'; END IF;
  v := public.new_stock_po(i.supplier_id, NULL, coalesce(nullif(btrim(p_what), ''), 'From ' || CASE WHEN i.doc_type = 'credit' THEN 'credit ' ELSE 'invoice ' END || i.supplier_invoice_number), 'other');
  v_po := coalesce(nullif(v ->> 'id', '')::bigint, (SELECT id FROM purchase_orders WHERE po_number = v ->> 'po_number' ORDER BY id DESC LIMIT 1));
  IF v_po IS NULL THEN RAISE EXCEPTION 'The PO couldn''t be made'; END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    q := coalesce((x ->> 'quantity')::numeric, 1); c := coalesce((x ->> 'unit_cost')::numeric, 0);
    IF q < 0 THEN q := -q; c := -c; END IF;            -- a returned item: the quantity stays above 0 and the cost goes minus
    IF q = 0 THEN IF c = 0 THEN CONTINUE; END IF; q := 1; END IF;
    IF btrim(coalesce(x ->> 'description', '')) = '' AND c = 0 THEN CONTINUE; END IF;
    INSERT INTO purchase_order_lines (purchase_order_id, description, quantity, unit_cost, quantity_received, job_id)
    VALUES (v_po, left(btrim(coalesce(x ->> 'description', '')), 500), q, c, q, NULL);
    n := n + 1;
  END LOOP;
  IF n = 0 THEN RAISE EXCEPTION 'Add at least one line'; END IF;
  UPDATE supplier_invoices SET purchase_order_id = v_po, updated_at = now() WHERE id = i.id;
  BEGIN UPDATE purchase_orders SET status = 'billed' WHERE id = v_po; EXCEPTION WHEN others THEN NULL; END;   -- the goods are already billed (or credited)
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('purchase_orders', v_po, 'insert', public.current_app_user_id(), jsonb_build_object('made_from_supplier_invoice', i.supplier_invoice_number, 'approved', true, 'lines', p_lines));
  RETURN jsonb_build_object('id', v_po, 'po_number', (SELECT po_number FROM purchase_orders WHERE id = v_po));
END $function$;

CREATE OR REPLACE FUNCTION public.po_full_save(p_id bigint, p jsonb, p_lines jsonb DEFAULT '[]', p_reason text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE po purchase_orders; x jsonb; l purchase_order_lines; v_new bigint; v_me bigint := public.current_app_user_id(); q numeric; c numeric;
BEGIN
  IF NOT public._po_can_edit() THEN RAISE EXCEPTION 'You need "Create POs" to change POs'; END IF;
  SELECT * INTO po FROM purchase_orders WHERE id = p_id; IF po.id IS NULL THEN RAISE EXCEPTION 'That PO isn''t in the app'; END IF;
  UPDATE purchase_orders SET
    status = CASE WHEN p ? 'status' THEN coalesce(nullif(p ->> 'status', ''), status) ELSE status END,
    supplier_id = CASE WHEN p ? 'supplier_id' AND nullif(p ->> 'supplier_id', '') IS NOT NULL THEN (p ->> 'supplier_id')::bigint ELSE supplier_id END,
    description = CASE WHEN p ? 'description' THEN nullif(btrim(p ->> 'description'), '') ELSE description END,
    notes = CASE WHEN p ? 'notes' THEN nullif(btrim(p ->> 'notes'), '') ELSE notes END,
    expected_on = CASE WHEN p ? 'expected_on' THEN nullif(p ->> 'expected_on', '')::date ELSE expected_on END,
    supplier_reference = CASE WHEN p ? 'supplier_reference' THEN nullif(btrim(p ->> 'supplier_reference'), '') ELSE supplier_reference END,
    amount = CASE WHEN p ? 'amount' THEN nullif(p ->> 'amount', '')::numeric ELSE amount END
  WHERE id = p_id;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p_lines, '[]')) LOOP
    -- quantities stay above 0: a minus quantity moves its minus to the cost; 0 with a cost counts as 1
    IF x ? 'quantity' OR x ? 'unit_cost' THEN
      q := coalesce((x ->> 'quantity')::numeric, 1); c := coalesce((x ->> 'unit_cost')::numeric, 0);
      IF q < 0 THEN q := -q; c := -c; END IF; IF q = 0 THEN q := 1; END IF;
      x := x || jsonb_build_object('quantity', q, 'unit_cost', c);
    END IF;
    IF x ? 'id' AND nullif(x ->> 'id', '') IS NOT NULL THEN
      SELECT * INTO l FROM purchase_order_lines WHERE id = (x ->> 'id')::bigint AND purchase_order_id = p_id; IF l.id IS NULL THEN CONTINUE; END IF;
      IF coalesce((x ->> 'delete')::boolean, false) THEN
        IF EXISTS (SELECT 1 FROM po_receipt_lines r WHERE r.purchase_order_line_id = l.id) THEN RAISE EXCEPTION 'Line "%" was already received, so it can''t be taken off. Change its quantity instead.', l.description; END IF;
        DELETE FROM purchase_order_lines WHERE id = l.id;
        INSERT INTO po_line_changes (purchase_order_id, po_line_id, action, old_values, reason, changed_by)
        VALUES (p_id, l.id, 'delete', jsonb_build_object('description', l.description, 'quantity', l.quantity, 'unit_cost', l.unit_cost), p_reason, v_me);
      ELSIF btrim(coalesce(x ->> 'description', l.description)) IS DISTINCT FROM l.description OR coalesce((x ->> 'quantity')::numeric, l.quantity) IS DISTINCT FROM l.quantity
            OR coalesce((x ->> 'unit_cost')::numeric, l.unit_cost) IS DISTINCT FROM l.unit_cost THEN
        UPDATE purchase_order_lines SET description = btrim(coalesce(x ->> 'description', description)), quantity = coalesce((x ->> 'quantity')::numeric, quantity),
               unit_cost = coalesce((x ->> 'unit_cost')::numeric, unit_cost) WHERE id = l.id;
        INSERT INTO po_line_changes (purchase_order_id, po_line_id, action, old_values, new_values, reason, changed_by)
        VALUES (p_id, l.id, 'edit', jsonb_build_object('description', l.description, 'quantity', l.quantity, 'unit_cost', l.unit_cost),
                (SELECT jsonb_build_object('description', description, 'quantity', quantity, 'unit_cost', unit_cost) FROM purchase_order_lines WHERE id = l.id), p_reason, v_me);
      END IF;
    ELSIF btrim(coalesce(x ->> 'description', '')) <> '' OR coalesce((x ->> 'unit_cost')::numeric, 0) <> 0 THEN
      INSERT INTO purchase_order_lines (purchase_order_id, description, quantity, unit_cost, quantity_received, job_id)
      VALUES (p_id, btrim(coalesce(x ->> 'description', 'Item')), coalesce((x ->> 'quantity')::numeric, 1), coalesce((x ->> 'unit_cost')::numeric, 0), 0, po.job_id)
      RETURNING id INTO v_new;
      INSERT INTO po_line_changes (purchase_order_id, po_line_id, action, new_values, reason, changed_by)
      VALUES (p_id, v_new, 'add', jsonb_build_object('description', btrim(coalesce(x ->> 'description', 'Item')), 'quantity', coalesce((x ->> 'quantity')::numeric, 1), 'unit_cost', coalesce((x ->> 'unit_cost')::numeric, 0)), p_reason, v_me);
    END IF;
  END LOOP;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('purchase_orders', p_id, 'update', v_me, jsonb_build_object('po_page', p, 'lines', p_lines, 'reason', p_reason));
END $function$;
NOTIFY pgrst, 'reload schema';

-- Supplier invoices: an invoice (or credit) with no PO gets one made from its lines, once someone approves it.
-- The PO is made the same way as a new stock PO, gets the approved lines, is tied to the invoice, and is marked Billed.
CREATE OR REPLACE FUNCTION public.supplier_invoice_make_po(p_invoice bigint, p_lines jsonb, p_what text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i supplier_invoices; v jsonb; v_po bigint; x jsonb; n int := 0;
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
    IF btrim(coalesce(x ->> 'description', '')) = '' AND coalesce((x ->> 'unit_cost')::numeric, 0) = 0 THEN CONTINUE; END IF;
    INSERT INTO purchase_order_lines (purchase_order_id, description, quantity, unit_cost, quantity_received, job_id)
    VALUES (v_po, left(btrim(coalesce(x ->> 'description', '')), 500), coalesce((x ->> 'quantity')::numeric, 1), coalesce((x ->> 'unit_cost')::numeric, 0), coalesce((x ->> 'quantity')::numeric, 1), NULL);
    n := n + 1;
  END LOOP;
  IF n = 0 THEN RAISE EXCEPTION 'Add at least one line'; END IF;
  UPDATE supplier_invoices SET purchase_order_id = v_po, updated_at = now() WHERE id = i.id;
  BEGIN UPDATE purchase_orders SET status = 'billed' WHERE id = v_po; EXCEPTION WHEN others THEN NULL; END;   -- the goods are already billed (or credited)
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('purchase_orders', v_po, 'insert', public.current_app_user_id(), jsonb_build_object('made_from_supplier_invoice', i.supplier_invoice_number, 'approved', true, 'lines', p_lines));
  RETURN jsonb_build_object('id', v_po, 'po_number', (SELECT po_number FROM purchase_orders WHERE id = v_po));
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_make_po(bigint, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_make_po(bigint, jsonb, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

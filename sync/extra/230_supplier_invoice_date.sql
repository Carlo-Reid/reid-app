-- Supplier invoices: the date can be changed by hand (e.g. a packing slip whose 04/10/26 was read as Oct 4). Safe to run more than once.
CREATE OR REPLACE FUNCTION public.supplier_invoice_set(p_id bigint, p jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_po bigint;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF p ? 'po_number' THEN
    IF nullif(btrim(p ->> 'po_number'), '') IS NULL THEN v_po := NULL;
    ELSE SELECT id INTO v_po FROM purchase_orders WHERE po_number = btrim(p ->> 'po_number') OR split_part(po_number, '-', 1) = btrim(p ->> 'po_number') ORDER BY (po_number = btrim(p ->> 'po_number')) DESC LIMIT 1;
      IF v_po IS NULL THEN RAISE EXCEPTION 'There''s no PO % in the app', btrim(p ->> 'po_number'); END IF; END IF;
    UPDATE supplier_invoices SET purchase_order_id = v_po, updated_at = now() WHERE id = p_id; END IF;
  IF p ? 'match_state' THEN UPDATE supplier_invoices SET match_state = nullif(p ->> 'match_state', ''), matched_by = public.current_app_user_id(), matched_at = now(), updated_at = now() WHERE id = p_id; END IF;
  IF p ? 'match_note' THEN UPDATE supplier_invoices SET match_note = nullif(btrim(p ->> 'match_note'), ''), updated_at = now() WHERE id = p_id; END IF;
  IF p ? 'invoice_date' THEN
    IF nullif(p ->> 'invoice_date', '') IS NULL THEN RAISE EXCEPTION 'Pick a date'; END IF;
    UPDATE supplier_invoices SET invoice_date = (p ->> 'invoice_date')::date, updated_at = now() WHERE id = p_id; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('supplier_invoices', p_id, 'update', public.current_app_user_id(), p);
END $function$;
NOTIFY pgrst, 'reload schema';

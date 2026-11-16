-- An open supplier invoice: change its number, and delete it for good (Carlo, Nov 16, 2026). Safe to run more than once.
CREATE OR REPLACE FUNCTION public.supplier_invoice_number_set(p_id bigint, p_number text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE o supplier_invoices; v text := btrim(coalesce(p_number, ''));
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  SELECT * INTO o FROM supplier_invoices WHERE id = p_id; IF o.id IS NULL THEN RAISE EXCEPTION 'That supplier invoice isn''t there any more'; END IF;
  IF v = '' THEN RAISE EXCEPTION 'Type the invoice number'; END IF;
  IF v = coalesce(o.supplier_invoice_number, '') THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM supplier_invoices x WHERE x.supplier_id = o.supplier_id AND x.id <> p_id AND lower(x.supplier_invoice_number) = lower(v)) THEN
    RAISE EXCEPTION 'This supplier already has an invoice numbered %', v; END IF;
  UPDATE supplier_invoices SET supplier_invoice_number = v, updated_at = now(),
         read_notes = concat_ws(' · ', nullif(read_notes, ''), 'Number changed by hand to ' || v || ' (was ' || coalesce(o.supplier_invoice_number, 'none') || ')') WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('supplier_invoices', p_id, 'update', public.current_app_user_id(), jsonb_build_object('number', o.supplier_invoice_number), jsonb_build_object('number', v));
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_number_set(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_number_set(bigint, text) TO authenticated;

-- Delete for good: owners only. Refused when money or stock hangs on it; what it was is kept in the history (audit_log), without the scanned pages.
CREATE OR REPLACE FUNCTION public.supplier_invoice_delete(p_id bigint, p_dry boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE o supplier_invoices; why text; n_pages int; n_lines int;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only an owner can delete a supplier invoice'; END IF;
  SELECT * INTO o FROM supplier_invoices WHERE id = p_id; IF o.id IS NULL THEN RAISE EXCEPTION 'That supplier invoice isn''t there any more'; END IF;
  why := CASE
    WHEN EXISTS (SELECT 1 FROM third_party_supplier_payments WHERE supplier_invoice_id = p_id) THEN 'a partner''s tank payment is tied to it'
    WHEN EXISTS (SELECT 1 FROM bank_sinv_links WHERE supplier_invoice_id = p_id) THEN 'a bank line is attached to it (take it off on the Bank page first)'
    WHEN EXISTS (SELECT 1 FROM supplier_returns WHERE supplier_invoice_id = p_id OR credit_invoice_id = p_id) THEN 'a return to the supplier is tied to it'
    WHEN EXISTS (SELECT 1 FROM supplier_invoice_stock WHERE supplier_invoice_id = p_id) THEN 'its parts were put in our stock (undo that in Stock history first)'
    WHEN EXISTS (SELECT 1 FROM supplier_credit_memos WHERE supplier_invoice_id = p_id AND tank_order_id IS NOT NULL) THEN 'its Credit Memo answered a Credit Order'
  END;
  SELECT count(*) INTO n_pages FROM supplier_doc_pages WHERE supplier_invoice_id = p_id;
  SELECT count(*) INTO n_lines FROM supplier_statement_lines WHERE supplier_invoice_id = p_id;
  IF p_dry THEN RETURN jsonb_build_object('ok', why IS NULL, 'why', why, 'pages', n_pages, 'statement_lines', n_lines,
    'memo', (SELECT memo_number FROM supplier_credit_memos WHERE supplier_invoice_id = p_id LIMIT 1)); END IF;
  IF why IS NOT NULL THEN RAISE EXCEPTION 'It can not be deleted: %', why; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('supplier_invoices', p_id, 'delete', public.current_app_user_id(), to_jsonb(o), jsonb_build_object('why', 'Deleted for good from the open supplier invoice', 'pages', n_pages, 'statement_lines', n_lines));
  UPDATE supplier_statement_lines SET supplier_invoice_id = NULL WHERE supplier_invoice_id = p_id;
  UPDATE po_line_changes SET supplier_invoice_id = NULL WHERE supplier_invoice_id = p_id;
  DELETE FROM supplier_invoice_pairs WHERE supplier_invoice_id = p_id;
  DELETE FROM supplier_credit_memos WHERE supplier_invoice_id = p_id;
  DELETE FROM supplier_doc_pages WHERE supplier_invoice_id = p_id;
  DELETE FROM supplier_invoices WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'number', o.supplier_invoice_number);
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_delete(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_delete(bigint, boolean) TO authenticated;
NOTIFY pgrst, 'reload schema';

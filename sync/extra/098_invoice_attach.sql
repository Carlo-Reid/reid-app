-- Supplier invoices: an invoice that's on the statement but whose copy was never loaded: drop the PDF from the email in the app.
-- Its pages are kept (like the scanned ones), and what was read off it (the PO number, subtotal, HST) fills in what's missing.
CREATE OR REPLACE FUNCTION public.supplier_invoice_attach(p_invoice bigint, p jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i supplier_invoices; x jsonb; v_n int; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to load supplier invoices'; END IF;
  SELECT * INTO i FROM supplier_invoices WHERE id = p_invoice; IF i.id IS NULL THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
  IF jsonb_typeof(p -> 'pages') <> 'array' OR jsonb_array_length(p -> 'pages') = 0 THEN RAISE EXCEPTION 'No pages to save'; END IF;
  SELECT coalesce(max(page_no), 0) INTO v_n FROM supplier_doc_pages WHERE supplier_invoice_id = p_invoice;
  FOR x IN SELECT * FROM jsonb_array_elements(p -> 'pages') LOOP
    v_n := v_n + 1;
    INSERT INTO supplier_doc_pages (statement_id, supplier_invoice_id, page_no, doc_number, kind, image)
    VALUES (NULL, p_invoice, v_n, i.supplier_invoice_number, coalesce(i.doc_type, 'invoice'), x #>> '{}');
  END LOOP;
  UPDATE supplier_invoices SET
    po_text = coalesce(nullif(btrim(p ->> 'po_text'), ''), po_text),
    subtotal = coalesce(subtotal, (p ->> 'subtotal')::numeric), hst = coalesce(hst, (p ->> 'hst')::numeric),
    lines = CASE WHEN jsonb_typeof(p -> 'lines') = 'array' AND jsonb_array_length(p -> 'lines') > 0 AND jsonb_array_length(coalesce(lines, '[]')) = 0 THEN p -> 'lines' ELSE lines END,
    read_notes = btrim(coalesce(read_notes, '') || ' Copy loaded in the app' || coalesce(' from ' || nullif(p ->> 'file', ''), '') || '.'),
    updated_at = now()
  WHERE id = p_invoice;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoices', p_invoice, 'update', v_me, jsonb_build_object('copy_loaded', p ->> 'file', 'pages', jsonb_array_length(p -> 'pages'), 'po_text', p ->> 'po_text', 'subtotal', p ->> 'subtotal', 'hst', p ->> 'hst'));
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_attach(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_attach(bigint, jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Supplier invoices: drop an invoice that isn't in the app yet (from the email): makes the invoice with its pages.
CREATE OR REPLACE FUNCTION public.supplier_invoice_add(p jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_sup bigint := (p ->> 'supplier_id')::bigint; v_num text := btrim(coalesce(p ->> 'number', '')); v_id bigint;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to load supplier invoices'; END IF;
  IF v_sup IS NULL OR v_num = '' THEN RAISE EXCEPTION 'Put in the invoice number'; END IF;
  SELECT id INTO v_id FROM supplier_invoices WHERE supplier_id = v_sup AND supplier_invoice_number = v_num;
  IF v_id IS NULL THEN
    INSERT INTO supplier_invoices (supplier_id, supplier_invoice_number, invoice_date, total, doc_type, po_text, subtotal, hst, lines, read_notes)
    VALUES (v_sup, v_num, (p ->> 'date')::date, coalesce((p ->> 'total')::numeric, (SELECT l.amount FROM supplier_statement_lines l JOIN supplier_statements s ON s.id = l.statement_id WHERE s.supplier_id = v_sup AND l.reference = v_num ORDER BY s.statement_date DESC LIMIT 1), 0), CASE WHEN (p ->> 'total')::numeric < 0 THEN 'credit' ELSE 'invoice' END,
            nullif(btrim(p ->> 'po_text'), ''), (p ->> 'subtotal')::numeric, (p ->> 'hst')::numeric, '[]', 'Loaded in the app from ' || coalesce(p ->> 'file', 'a file') || '.')
    RETURNING id INTO v_id;
    -- a statement line with this number gets tied to it
    UPDATE supplier_statement_lines l SET supplier_invoice_id = v_id FROM supplier_statements s
      WHERE s.id = l.statement_id AND s.supplier_id = v_sup AND l.reference = v_num AND l.supplier_invoice_id IS NULL;
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('supplier_invoices', v_id, 'insert', public.current_app_user_id(), p - 'pages');
  END IF;
  PERFORM public.supplier_invoice_attach(v_id, p);
  RETURN v_id;
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_add(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_add(jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';

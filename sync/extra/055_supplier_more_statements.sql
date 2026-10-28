-- Supplier invoices: loading more statements (Boone January to August 2026).
-- An invoice that isn't paid shows again on the next statements; it stays with the first statement it was billed on (and keeps that date).
CREATE OR REPLACE FUNCTION public.supplier_docs_import(p jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_st bigint; v_sup bigint := (p ->> 'supplier_id')::bigint; x jsonb; v_inv bigint;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Owners only'; END IF;
  INSERT INTO supplier_statements (supplier_id, statement_date, total, aging, file_name, pages, created_by)
  VALUES (v_sup, (p ->> 'statement_date')::date, (p ->> 'total')::numeric, p -> 'aging', p ->> 'file_name', (p ->> 'pages')::int, public.current_app_user_id())
  ON CONFLICT (supplier_id, statement_date) DO UPDATE SET total = EXCLUDED.total, aging = EXCLUDED.aging, file_name = EXCLUDED.file_name, pages = EXCLUDED.pages
  RETURNING id INTO v_st;
  FOR x IN SELECT * FROM jsonb_array_elements(p -> 'invoices') LOOP
    INSERT INTO supplier_invoices (supplier_id, supplier_invoice_number, invoice_date, total, doc_type, po_text, job_name, original_order, subtotal, hst, lines, handwriting, read_notes, statement_id)
    VALUES (v_sup, x ->> 'number', (x ->> 'date')::date, (x ->> 'total')::numeric, coalesce(x ->> 'doc_type', 'invoice'), nullif(x ->> 'po_text', ''), nullif(x ->> 'job_name', ''),
            nullif(x ->> 'original_order', ''), (x ->> 'subtotal')::numeric, (x ->> 'hst')::numeric, coalesce(x -> 'lines', '[]'), nullif(x ->> 'handwriting', ''), nullif(x ->> 'read_notes', ''), v_st)
    ON CONFLICT (supplier_id, supplier_invoice_number) DO UPDATE SET total = EXCLUDED.total, doc_type = EXCLUDED.doc_type,
      po_text = coalesce(EXCLUDED.po_text, supplier_invoices.po_text), job_name = coalesce(EXCLUDED.job_name, supplier_invoices.job_name), original_order = coalesce(EXCLUDED.original_order, supplier_invoices.original_order),
      subtotal = coalesce(EXCLUDED.subtotal, supplier_invoices.subtotal), hst = coalesce(EXCLUDED.hst, supplier_invoices.hst),
      lines = CASE WHEN jsonb_array_length(EXCLUDED.lines) > 0 THEN EXCLUDED.lines ELSE supplier_invoices.lines END,
      handwriting = coalesce(EXCLUDED.handwriting, supplier_invoices.handwriting), read_notes = coalesce(EXCLUDED.read_notes, supplier_invoices.read_notes),
      -- an invoice shows on every statement until it's paid: it belongs to the first (earliest) statement it was billed on
      statement_id = CASE WHEN supplier_invoices.statement_id IS NOT NULL
                           AND (SELECT statement_date FROM supplier_statements WHERE id = supplier_invoices.statement_id) <= (SELECT statement_date FROM supplier_statements WHERE id = EXCLUDED.statement_id)
                          THEN supplier_invoices.statement_id ELSE EXCLUDED.statement_id END,
      invoice_date = CASE WHEN supplier_invoices.statement_id IS NOT NULL
                           AND (SELECT statement_date FROM supplier_statements WHERE id = supplier_invoices.statement_id) <= (SELECT statement_date FROM supplier_statements WHERE id = EXCLUDED.statement_id)
                          THEN coalesce(supplier_invoices.invoice_date, EXCLUDED.invoice_date) ELSE EXCLUDED.invoice_date END,
      updated_at = now()
    RETURNING id INTO v_inv;
  END LOOP;
  FOR x IN SELECT * FROM jsonb_array_elements(p -> 'statement_lines') LOOP
    INSERT INTO supplier_statement_lines (statement_id, reference, doc_date, code, amount, branch, supplier_invoice_id)
    VALUES (v_st, x ->> 'reference', (x ->> 'date')::date, x ->> 'code', (x ->> 'amount')::numeric, x ->> 'branch',
            (SELECT id FROM supplier_invoices WHERE supplier_id = v_sup AND supplier_invoice_number = x ->> 'reference'))
    ON CONFLICT (statement_id, reference) DO UPDATE SET doc_date = EXCLUDED.doc_date, code = EXCLUDED.code, amount = EXCLUDED.amount, supplier_invoice_id = EXCLUDED.supplier_invoice_id;
  END LOOP;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('supplier_statements', v_st, 'insert', public.current_app_user_id(),
    jsonb_build_object('file', p ->> 'file_name', 'invoices', jsonb_array_length(p -> 'invoices'), 'lines', jsonb_array_length(p -> 'statement_lines')));
  RETURN v_st;
END $function$;
NOTIFY pgrst, 'reload schema';

-- Supplier invoices: an invoice that's on the statement but whose copy was never loaded: drop the PDF from the email in the app.
-- Its pages are kept (like the scanned ones), and what was read off it (the PO number, subtotal, HST) fills in what's missing.
CREATE OR REPLACE FUNCTION public.supplier_invoice_attach(p_invoice bigint, p jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i supplier_invoices; x jsonb; v_n int; v_me bigint := public.current_app_user_id();
  v_sys boolean; v_tot numeric; v_sub numeric; v_hst numeric; v_date date; v_keep boolean; v_note text;
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
  -- The record was made by the app (from a statement line, a system copy, or a lost invoice) and the supplier's own paper is now
  -- loaded: the paper replaces what the app made (Carlo, Nov 17, 2026). Not for a packing slip, which has no amounts.
  v_sys := coalesce(i.read_notes, '') ~* '(System generated copy made in the app|Made by the app (from their statement|on )|because the original was lost)'
           AND coalesce(p ->> 'file', '') NOT ILIKE 'the packing slip%';
  IF v_sys THEN
    v_tot := CASE WHEN p ->> 'total' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (p ->> 'total')::numeric END;
    v_sub := CASE WHEN p ->> 'subtotal' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (p ->> 'subtotal')::numeric END;
    v_hst := CASE WHEN p ->> 'hst' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (p ->> 'hst')::numeric END;
    v_date := CASE WHEN p ->> 'date' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN left(p ->> 'date', 10)::date END;
    -- the total is only taken from the paper when it agrees with ours (within $1) or we have none: a misread total must not break the statement
    v_keep := v_tot IS NOT NULL AND coalesce(i.total, 0) <> 0 AND abs(v_tot - i.total) > 1;
    v_note := 'The supplier''s original was loaded on ' || to_char(now() AT TIME ZONE 'America/Toronto', 'Mon FMDD, YYYY') || coalesce(' from ' || nullif(p ->> 'file', ''), '')
      || '. It replaced the copy the app made.'
      || CASE WHEN v_keep THEN ' CHECK: the paper reads a total of $' || to_char(v_tot, 'FM999,999,990.00') || ' and our record says $' || to_char(i.total, 'FM999,999,990.00') || '. Our total was kept.' ELSE '' END;
    UPDATE supplier_invoices SET
      invoice_date = coalesce(v_date, invoice_date),
      total = CASE WHEN v_tot IS NOT NULL AND NOT v_keep THEN v_tot ELSE total END,
      subtotal = CASE WHEN v_keep THEN subtotal ELSE coalesce(v_sub, subtotal) END,
      hst = CASE WHEN v_keep THEN hst ELSE coalesce(v_hst, hst) END,
      lines = CASE WHEN jsonb_typeof(p -> 'lines') = 'array' AND jsonb_array_length(p -> 'lines') > 0 THEN p -> 'lines' ELSE lines END,
      read_notes = v_note || ' Before: ' || replace(replace(replace(coalesce(i.read_notes, ''), 'System generated copy', 'System copy (now replaced)'), 'Made by the app', 'First made by the app'), 'the original was lost', 'the original was missing'),
      updated_at = now()
    WHERE id = p_invoice;
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
    VALUES ('supplier_invoices', p_invoice, 'update', v_me,
      jsonb_build_object('invoice_date', i.invoice_date, 'total', i.total, 'subtotal', i.subtotal, 'hst', i.hst, 'lines', i.lines, 'read_notes', i.read_notes),
      jsonb_build_object('replaced_system_copy', true, 'paper_total', v_tot, 'total_kept', v_keep));
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoices', p_invoice, 'update', v_me, jsonb_build_object('copy_loaded', p ->> 'file', 'pages', jsonb_array_length(p -> 'pages'), 'po_text', p ->> 'po_text', 'subtotal', p ->> 'subtotal', 'hst', p ->> 'hst'));
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_attach(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_attach(bigint, jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';

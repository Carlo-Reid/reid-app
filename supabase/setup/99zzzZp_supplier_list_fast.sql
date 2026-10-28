-- copy of sync/extra/056_supplier_list_fast.sql (run by the nightly sync)
-- Supplier invoices page: with Boone, Masters and Lennox loaded (about 1,800 invoices) the list was too slow to open.
-- Now it opens on the newest statement (one statement at a time), and "other invoices on the same PO" looks at every statement.
CREATE INDEX IF NOT EXISTS supplier_invoices_po_text ON public.supplier_invoices (btrim(po_text));
CREATE INDEX IF NOT EXISTS supplier_invoices_statement ON public.supplier_invoices (statement_id);
CREATE OR REPLACE FUNCTION public.supplier_invoices_list(p_supplier bigint DEFAULT NULL, p_statement bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off' AS $function$
DECLARE v_st bigint := p_statement;
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  IF v_st IS NULL THEN
    SELECT s.id INTO v_st FROM supplier_statements s WHERE p_supplier IS NULL OR s.supplier_id = p_supplier ORDER BY s.statement_date DESC, s.id DESC LIMIT 1;
  END IF;
  RETURN (SELECT jsonb_build_object(
    'statement_id', v_st,
    'statements', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'supplier_id', s.supplier_id, 'supplier', btrim(sp.name), 'date', s.statement_date, 'total', s.total, 'aging', s.aging,
                      'file', s.file_name, 'pages', s.pages, 'lines', (SELECT count(*) FROM supplier_statement_lines l WHERE l.statement_id = s.id)) ORDER BY s.statement_date DESC, sp.name), '[]')
                   FROM supplier_statements s JOIN suppliers sp ON sp.id = s.supplier_id WHERE p_supplier IS NULL OR s.supplier_id = p_supplier),
    'rows', (SELECT coalesce(jsonb_agg(r ORDER BY r.invoice_date DESC, r.number DESC), '[]') FROM (
      WITH m AS MATERIALIZED (SELECT i.id AS inv_id, public._sinv_po(i) AS po_id FROM supplier_invoices i
                              WHERE (p_supplier IS NULL OR i.supplier_id = p_supplier) AND i.statement_id = v_st)
      SELECT i.id, i.supplier_id, btrim(sp.name) AS supplier, i.supplier_invoice_number AS number, i.invoice_date, i.doc_type, i.po_text, i.job_name,
             i.subtotal, i.hst, i.total, jsonb_array_length(i.lines) AS line_count, i.match_state, i.match_note, i.statement_id, i.handwriting, i.read_notes,
             (SELECT count(*) FROM supplier_doc_pages d WHERE d.supplier_invoice_id = i.id) AS pages,
             po.id AS po_id, po.po_number, po.status AS po_status, po.job_id AS po_job_id, j.job_number AS po_job_number, c.id AS po_customer_id, c.display_name AS po_customer,
             (po.supplier_id IS DISTINCT FROM i.supplier_id) AS po_other_supplier, i.purchase_order_id IS NOT NULL AS po_by_hand,
             (SELECT round(sum(pl.line_total), 2) FROM purchase_order_lines pl WHERE pl.purchase_order_id = po.id) AS po_amount,
             (SELECT count(*) FROM purchase_order_lines pl WHERE pl.purchase_order_id = po.id) AS po_lines,
             CASE WHEN po.id IS NULL THEN 0 ELSE (SELECT count(*) FROM supplier_invoices o WHERE o.id <> i.id AND o.supplier_id = i.supplier_id AND o.total > 0
                    AND (o.purchase_order_id = po.id OR btrim(o.po_text) = po.po_number OR btrim(o.po_text) = split_part(po.po_number, '-', 1))) END AS po_other_invoices
      FROM m JOIN supplier_invoices i ON i.id = m.inv_id JOIN suppliers sp ON sp.id = i.supplier_id
      LEFT JOIN purchase_orders po ON po.id = m.po_id
      LEFT JOIN jobs j ON j.id = po.job_id LEFT JOIN customers c ON c.id = j.customer_id
      ) r),
    'statement_lines', (SELECT coalesce(jsonb_agg(jsonb_build_object('reference', l.reference, 'date', l.doc_date, 'code', l.code,
                      'amount', l.amount, 'branch', l.branch, 'invoice_id', l.supplier_invoice_id) ORDER BY l.id), '[]') FROM supplier_statement_lines l WHERE l.statement_id = v_st),
    'can_edit', public._sinv_can_edit()));
END $function$;
NOTIFY pgrst, 'reload schema';

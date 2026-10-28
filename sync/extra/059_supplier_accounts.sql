-- Supplier invoices: one supplier can send statements for more than one of our accounts (Trent: 4112 main and 4161 water heaters),
-- sometimes with the same date. Statements are now one per supplier + date + account.
ALTER TABLE public.supplier_statements ADD COLUMN IF NOT EXISTS account text NOT NULL DEFAULT '';
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'supplier_statements_supplier_id_statement_date_key') THEN
    ALTER TABLE public.supplier_statements DROP CONSTRAINT supplier_statements_supplier_id_statement_date_key; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'supplier_statements_sup_date_acct_key') THEN
    ALTER TABLE public.supplier_statements ADD CONSTRAINT supplier_statements_sup_date_acct_key UNIQUE (supplier_id, statement_date, account); END IF;
END $$;
CREATE OR REPLACE FUNCTION public.supplier_docs_import(p jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_st bigint; v_sup bigint := (p ->> 'supplier_id')::bigint; x jsonb; v_inv bigint;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Owners only'; END IF;
  INSERT INTO supplier_statements (supplier_id, statement_date, account, total, aging, file_name, pages, created_by)
  VALUES (v_sup, (p ->> 'statement_date')::date, coalesce(p ->> 'account', ''), (p ->> 'total')::numeric, p -> 'aging', p ->> 'file_name', (p ->> 'pages')::int, public.current_app_user_id())
  ON CONFLICT (supplier_id, statement_date, account) DO UPDATE SET total = EXCLUDED.total, aging = EXCLUDED.aging, file_name = EXCLUDED.file_name, pages = EXCLUDED.pages
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

CREATE OR REPLACE FUNCTION public.supplier_invoices_list(p_supplier bigint DEFAULT NULL, p_statement bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off' AS $function$
DECLARE v_st bigint := p_statement;
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  IF v_st IS NULL THEN  -- newest statement (of the supplier picked)
    SELECT s.id INTO v_st FROM supplier_statements s WHERE p_supplier IS NULL OR s.supplier_id = p_supplier ORDER BY s.statement_date DESC, s.id DESC LIMIT 1;
  END IF;
  RETURN (SELECT jsonb_build_object(
    'statement_id', v_st,
    'statements', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'supplier_id', s.supplier_id, 'account', nullif(s.account, ''), 'supplier', btrim(sp.name), 'date', s.statement_date, 'total', s.total, 'aging', s.aging,
                      'file', s.file_name, 'pages', s.pages, 'lines', (SELECT count(*) FROM supplier_statement_lines l WHERE l.statement_id = s.id)) ORDER BY s.statement_date DESC, sp.name), '[]')
                   FROM supplier_statements s JOIN suppliers sp ON sp.id = s.supplier_id),
    'rows', (SELECT coalesce(jsonb_agg(r ORDER BY r.invoice_date DESC, r.number DESC), '[]') FROM (
      WITH m AS MATERIALIZED (SELECT i.id AS inv_id, public._sinv_po(i) AS po_id FROM supplier_invoices i
                              WHERE (p_supplier IS NULL OR i.supplier_id = p_supplier) AND (v_st = 0 OR i.statement_id = v_st))
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
    'invoice_counts', (SELECT coalesce(jsonb_object_agg(x.supplier_id, x.n), '{}') FROM (SELECT supplier_id, count(*) AS n FROM supplier_invoices GROUP BY supplier_id) x),
    'can_edit', public._sinv_can_edit()));
END $function$;
NOTIFY pgrst, 'reload schema';

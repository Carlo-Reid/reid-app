-- =====================================================================
-- Supplier invoices page:
--   * Their statement's scanned pages are kept with it (saved with the statement, or added later), to view and print.
--   * Our statement: what our records say for a supplier as of a date (our invoices and credits, our payments), with
--     their statement for that date beside it to match against. The page works out the balance and the aging.
-- Same people as the Supplier invoices page. Safe to run more than once.
-- =====================================================================

-- keep the pages of a statement (replaces any pages kept before)
CREATE OR REPLACE FUNCTION public.supplier_statement_pages_set(p_statement bigint, p_pages jsonb) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE x jsonb; n int := 0;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier statements'; END IF;
  IF NOT EXISTS (SELECT 1 FROM supplier_statements WHERE id = p_statement) THEN RAISE EXCEPTION 'That statement is gone'; END IF;
  IF jsonb_typeof(p_pages) <> 'array' OR jsonb_array_length(p_pages) = 0 THEN RAISE EXCEPTION 'No pages to save'; END IF;
  DELETE FROM supplier_doc_pages WHERE statement_id = p_statement AND supplier_invoice_id IS NULL AND kind = 'statement';
  FOR x IN SELECT * FROM jsonb_array_elements(p_pages) LOOP
    n := n + 1;
    INSERT INTO supplier_doc_pages (statement_id, supplier_invoice_id, page_no, doc_number, kind, image)
    VALUES (p_statement, NULL, 1000 + n, NULL, 'statement', x #>> '{}')
    ON CONFLICT (statement_id, page_no) DO UPDATE SET image = EXCLUDED.image, kind = 'statement', supplier_invoice_id = NULL;
  END LOOP;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_statements', p_statement, 'update', public.current_app_user_id(), jsonb_build_object('pages_kept', n));
  RETURN n;
END $f$;

-- the pages of a statement, in order (the ones kept with it; else any pages an earlier import saved with it)
CREATE OR REPLACE FUNCTION public.supplier_statement_pages(p_statement bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL OR NOT (public._sinv_can_edit() OR public._can_see_costs()) THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('n', p.page_no, 'image', p.image) ORDER BY p.page_no) FROM supplier_doc_pages p
    WHERE p.statement_id = p_statement AND p.image IS NOT NULL
      AND (p.kind = 'statement' OR NOT EXISTS (SELECT 1 FROM supplier_doc_pages q WHERE q.statement_id = p_statement AND q.kind = 'statement'))), '[]') END $f$;

-- a supplier's statements, newest first, with how many pages are kept for each
CREATE OR REPLACE FUNCTION public.supplier_statements_pages(p_supplier bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL OR NOT (public._sinv_can_edit() OR public._can_see_costs()) THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', s.id, 'date', s.statement_date, 'total', s.total, 'account', s.account, 'file', s.file_name,
             'lines', (SELECT count(*) FROM supplier_statement_lines l WHERE l.statement_id = s.id),
             'pages', (SELECT count(*) FROM supplier_doc_pages p WHERE p.statement_id = s.id AND p.image IS NOT NULL AND (p.kind = 'statement'
                        OR NOT EXISTS (SELECT 1 FROM supplier_doc_pages q WHERE q.statement_id = s.id AND q.kind = 'statement'))),
             'accepted_at', s.accepted_at) ORDER BY s.statement_date DESC, s.id DESC)
    FROM supplier_statements s WHERE s.supplier_id = p_supplier), '[]') END $f$;

-- our records for a supplier as of a date, and their statement for that date (or the one before it) to match against
CREATE OR REPLACE FUNCTION public.supplier_our_statement(p_supplier bigint, p_as_of date) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL OR NOT (public._sinv_can_edit() OR public._can_see_costs()) THEN NULL ELSE jsonb_build_object(
    'supplier', (SELECT btrim(name) FROM suppliers WHERE id = p_supplier), 'as_of', p_as_of,
    'invoices', coalesce((SELECT jsonb_agg(jsonb_build_object('id', i.id, 'number', i.supplier_invoice_number, 'date', i.invoice_date, 'total', i.total,
                   'type', coalesce(i.doc_type, 'invoice'), 'po', coalesce(nullif(btrim(i.po_text), ''), (SELECT po.po_number FROM purchase_orders po WHERE po.id = public._sinv_po(i))))
                   ORDER BY i.invoice_date, i.supplier_invoice_number)
                 FROM supplier_invoices i WHERE i.supplier_id = p_supplier AND i.total IS NOT NULL AND coalesce(i.invoice_date, i.created_at::date) <= p_as_of
                   AND coalesce(i.doc_type, 'invoice') IN ('invoice', 'credit')), '[]'),
    'payments', coalesce((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'date', p.paid_on, 'amount', p.amount, 'method', p.method, 'reference', p.reference) ORDER BY p.paid_on, p.id)
                 FROM supplier_payments p WHERE p.supplier_id = p_supplier AND p.voided_at IS NULL AND p.paid_on <= p_as_of), '[]'),
    'their', (SELECT jsonb_build_object('id', s.id, 'date', s.statement_date, 'total', s.total, 'aging', s.aging,
                'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('reference', l.reference, 'date', l.doc_date, 'code', l.code, 'amount', l.amount) ORDER BY l.doc_date, l.reference)
                  FROM supplier_statement_lines l WHERE l.statement_id = s.id), '[]'))
              FROM supplier_statements s WHERE s.supplier_id = p_supplier AND s.statement_date <= p_as_of ORDER BY s.statement_date DESC, s.id DESC LIMIT 1),
    'statements', coalesce((SELECT jsonb_agg(s.statement_date ORDER BY s.statement_date DESC) FROM supplier_statements s WHERE s.supplier_id = p_supplier), '[]')) END $f$;

REVOKE EXECUTE ON FUNCTION public.supplier_statement_pages_set(bigint, jsonb), public.supplier_statement_pages(bigint), public.supplier_statements_pages(bigint),
  public.supplier_our_statement(bigint, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_statement_pages_set(bigint, jsonb), public.supplier_statement_pages(bigint), public.supplier_statements_pages(bigint),
  public.supplier_our_statement(bigint, date) TO authenticated;
NOTIFY pgrst, 'reload schema';

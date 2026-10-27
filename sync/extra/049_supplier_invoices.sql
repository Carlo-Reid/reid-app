-- Supplier invoices page: every supplier invoice / credit we get (starting with Boone's monthly statement + the invoices behind it),
-- each matched to our PO by the PO number printed on it. Scans of the pages are kept so the original can be looked at.
-- Who sees it: people who can see costs. Who changes matches / notes: owners and people who can make POs.
ALTER TABLE public.supplier_invoices
  ADD COLUMN IF NOT EXISTS doc_type text NOT NULL DEFAULT 'invoice',      -- invoice / credit / charge (service charge)
  ADD COLUMN IF NOT EXISTS po_text text,                                   -- the customer PO box exactly as printed (a number, or a name like GEORGE)
  ADD COLUMN IF NOT EXISTS job_name text,
  ADD COLUMN IF NOT EXISTS original_order text,
  ADD COLUMN IF NOT EXISTS subtotal numeric(12,2),
  ADD COLUMN IF NOT EXISTS hst numeric(12,2),
  ADD COLUMN IF NOT EXISTS lines jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS handwriting text,
  ADD COLUMN IF NOT EXISTS read_notes text,                                -- what was hard to read on the scan
  ADD COLUMN IF NOT EXISTS statement_id bigint,
  ADD COLUMN IF NOT EXISTS match_state text,                               -- ok (checked by a person) / null = work it out
  ADD COLUMN IF NOT EXISTS match_note text,
  ADD COLUMN IF NOT EXISTS matched_by bigint,
  ADD COLUMN IF NOT EXISTS matched_at timestamptz;
CREATE TABLE IF NOT EXISTS public.supplier_statements (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, supplier_id bigint NOT NULL REFERENCES suppliers(id), statement_date date NOT NULL,
  total numeric(12,2), aging jsonb, file_name text, pages int, created_at timestamptz NOT NULL DEFAULT now(), created_by bigint,
  UNIQUE (supplier_id, statement_date));
CREATE TABLE IF NOT EXISTS public.supplier_statement_lines (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, statement_id bigint NOT NULL REFERENCES supplier_statements(id) ON DELETE CASCADE,
  reference text NOT NULL, doc_date date, code text, amount numeric(12,2) NOT NULL, branch text, supplier_invoice_id bigint REFERENCES supplier_invoices(id),
  UNIQUE (statement_id, reference));
CREATE TABLE IF NOT EXISTS public.supplier_doc_pages (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, statement_id bigint REFERENCES supplier_statements(id) ON DELETE CASCADE,
  supplier_invoice_id bigint REFERENCES supplier_invoices(id) ON DELETE SET NULL, page_no int NOT NULL, doc_number text, kind text, image text,
  UNIQUE (statement_id, page_no));
CREATE INDEX IF NOT EXISTS supplier_doc_pages_inv ON public.supplier_doc_pages (supplier_invoice_id);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'supplier_invoices_statement_fk') THEN
    ALTER TABLE public.supplier_invoices ADD CONSTRAINT supplier_invoices_statement_fk FOREIGN KEY (statement_id) REFERENCES supplier_statements(id) ON DELETE SET NULL; END IF;
END $$;
ALTER TABLE public.supplier_invoices ENABLE ROW LEVEL SECURITY; ALTER TABLE public.supplier_statements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_statement_lines ENABLE ROW LEVEL SECURITY; ALTER TABLE public.supplier_doc_pages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.supplier_invoices, public.supplier_statements, public.supplier_statement_lines, public.supplier_doc_pages FROM anon, authenticated;

CREATE INDEX IF NOT EXISTS purchase_orders_po_base ON public.purchase_orders (split_part(po_number, '-', 1));
CREATE OR REPLACE FUNCTION public._sinv_can_edit() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.current_staff_role() = 'owner' OR public.has_permission('po.create') $$;
-- the PO an invoice belongs to: the one picked by hand, or the PO with the number printed on it (same supplier first)
CREATE OR REPLACE FUNCTION public._sinv_po(p_inv supplier_invoices) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(p_inv.purchase_order_id,
    (SELECT po.id FROM purchase_orders po WHERE p_inv.po_text ~ '^[0-9][0-9-]{5,}$'
       AND (po.po_number = btrim(p_inv.po_text) OR split_part(po.po_number, '-', 1) = btrim(p_inv.po_text))
     ORDER BY (po.supplier_id = p_inv.supplier_id) DESC, (po.po_number = btrim(p_inv.po_text)) DESC, po.id LIMIT 1)) $$;

-- the list: every invoice / credit, with its PO and how the amounts compare
CREATE OR REPLACE FUNCTION public.supplier_invoices_list(p_supplier bigint DEFAULT NULL, p_statement bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  RETURN (SELECT jsonb_build_object(
    'statements', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'supplier_id', s.supplier_id, 'supplier', btrim(sp.name), 'date', s.statement_date, 'total', s.total, 'aging', s.aging,
                      'file', s.file_name, 'pages', s.pages, 'lines', (SELECT count(*) FROM supplier_statement_lines l WHERE l.statement_id = s.id)) ORDER BY s.statement_date DESC), '[]')
                   FROM supplier_statements s JOIN suppliers sp ON sp.id = s.supplier_id WHERE p_supplier IS NULL OR s.supplier_id = p_supplier),
    'rows', (SELECT coalesce(jsonb_agg(r ORDER BY r.invoice_date DESC, r.number DESC), '[]') FROM (
      WITH m AS MATERIALIZED (SELECT i.id AS inv_id, public._sinv_po(i) AS po_id FROM supplier_invoices i
                              WHERE (p_supplier IS NULL OR i.supplier_id = p_supplier) AND (p_statement IS NULL OR i.statement_id = p_statement))
      SELECT i.id, i.supplier_id, btrim(sp.name) AS supplier, i.supplier_invoice_number AS number, i.invoice_date, i.doc_type, i.po_text, i.job_name,
             i.subtotal, i.hst, i.total, jsonb_array_length(i.lines) AS line_count, i.match_state, i.match_note, i.statement_id, i.handwriting, i.read_notes,
             (SELECT count(*) FROM supplier_doc_pages d WHERE d.supplier_invoice_id = i.id) AS pages,
             po.id AS po_id, po.po_number, po.status AS po_status, po.job_id AS po_job_id, j.job_number AS po_job_number, c.id AS po_customer_id, c.display_name AS po_customer,
             (po.supplier_id IS DISTINCT FROM i.supplier_id) AS po_other_supplier, i.purchase_order_id IS NOT NULL AS po_by_hand,
             (SELECT round(sum(pl.line_total), 2) FROM purchase_order_lines pl WHERE pl.purchase_order_id = po.id) AS po_amount,
             (SELECT count(*) FROM purchase_order_lines pl WHERE pl.purchase_order_id = po.id) AS po_lines,
             (SELECT count(*) FROM m o WHERE o.inv_id <> i.id AND o.po_id = po.id) AS po_other_invoices
      FROM m JOIN supplier_invoices i ON i.id = m.inv_id JOIN suppliers sp ON sp.id = i.supplier_id
      LEFT JOIN purchase_orders po ON po.id = m.po_id
      LEFT JOIN jobs j ON j.id = po.job_id LEFT JOIN customers c ON c.id = j.customer_id
      ) r),
    'statement_lines', CASE WHEN p_statement IS NULL THEN '[]'::jsonb ELSE (SELECT coalesce(jsonb_agg(jsonb_build_object('reference', l.reference, 'date', l.doc_date, 'code', l.code,
                      'amount', l.amount, 'branch', l.branch, 'invoice_id', l.supplier_invoice_id) ORDER BY l.id), '[]') FROM supplier_statement_lines l WHERE l.statement_id = p_statement) END,
    'can_edit', public._sinv_can_edit()));
END $function$;

-- one invoice: its lines, the PO's lines, and its scanned pages (ids; the pictures come one at a time)
CREATE OR REPLACE FUNCTION public.supplier_invoice_get(p_id bigint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i supplier_invoices; v_po bigint;
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  SELECT * INTO i FROM supplier_invoices WHERE id = p_id; IF i.id IS NULL THEN RAISE EXCEPTION 'Not found'; END IF;
  v_po := public._sinv_po(i);
  RETURN jsonb_build_object('lines', i.lines,
    'po_lines', (SELECT coalesce(jsonb_agg(jsonb_build_object('description', pl.description, 'quantity', pl.quantity, 'unit_cost', pl.unit_cost, 'line_total', pl.line_total,
                   'received', pl.quantity_received, 'sku', pi.sku) ORDER BY pl.id), '[]') FROM purchase_order_lines pl LEFT JOIN pricebook_items pi ON pi.id = pl.item_id WHERE pl.purchase_order_id = v_po),
    'pages', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'page_no', d.page_no) ORDER BY d.page_no), '[]') FROM supplier_doc_pages d WHERE d.supplier_invoice_id = p_id));
END $function$;
CREATE OR REPLACE FUNCTION public.supplier_doc_page(p_id bigint) RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  RETURN (SELECT image FROM supplier_doc_pages WHERE id = p_id); END $function$;

-- match by hand (a PO number, or empty to go back to the printed one), mark it checked, or add a note
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
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('supplier_invoices', p_id, 'update', public.current_app_user_id(), p);
END $function$;

-- loading a statement with its invoices (owners): the statement, its lines, and each invoice / credit read from the pages
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
    ON CONFLICT (supplier_id, supplier_invoice_number) DO UPDATE SET invoice_date = EXCLUDED.invoice_date, total = EXCLUDED.total, doc_type = EXCLUDED.doc_type,
      po_text = coalesce(EXCLUDED.po_text, supplier_invoices.po_text), job_name = coalesce(EXCLUDED.job_name, supplier_invoices.job_name), original_order = coalesce(EXCLUDED.original_order, supplier_invoices.original_order),
      subtotal = coalesce(EXCLUDED.subtotal, supplier_invoices.subtotal), hst = coalesce(EXCLUDED.hst, supplier_invoices.hst),
      lines = CASE WHEN jsonb_array_length(EXCLUDED.lines) > 0 THEN EXCLUDED.lines ELSE supplier_invoices.lines END,
      handwriting = coalesce(EXCLUDED.handwriting, supplier_invoices.handwriting), read_notes = coalesce(EXCLUDED.read_notes, supplier_invoices.read_notes), statement_id = EXCLUDED.statement_id, updated_at = now()
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
CREATE OR REPLACE FUNCTION public.supplier_doc_page_add(p_statement bigint, p_page int, p_doc text, p_kind text, p_image text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_sup bigint := (SELECT supplier_id FROM supplier_statements WHERE id = p_statement);
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Owners only'; END IF;
  INSERT INTO supplier_doc_pages (statement_id, page_no, doc_number, kind, image, supplier_invoice_id)
  VALUES (p_statement, p_page, nullif(p_doc, ''), p_kind, p_image, (SELECT id FROM supplier_invoices WHERE supplier_id = v_sup AND supplier_invoice_number = p_doc))
  ON CONFLICT (statement_id, page_no) DO UPDATE SET doc_number = EXCLUDED.doc_number, kind = EXCLUDED.kind, image = EXCLUDED.image, supplier_invoice_id = EXCLUDED.supplier_invoice_id;
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoices_list(bigint, bigint), public.supplier_invoice_get(bigint), public.supplier_doc_page(bigint), public.supplier_invoice_set(bigint, jsonb),
  public.supplier_docs_import(jsonb), public.supplier_doc_page_add(bigint, int, text, text, text), public._sinv_can_edit(), public._sinv_po(supplier_invoices) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoices_list(bigint, bigint), public.supplier_invoice_get(bigint), public.supplier_doc_page(bigint), public.supplier_invoice_set(bigint, jsonb),
  public.supplier_docs_import(jsonb), public.supplier_doc_page_add(bigint, int, text, text, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

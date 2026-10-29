-- Supplier invoices: fix a PO from the supplier's invoice (accept its prices / quantities, add the lines it billed),
-- or type your own, and keep a record of every change: who, when, which invoice, what it was and what it became.
CREATE TABLE IF NOT EXISTS public.po_line_changes (
  id bigserial PRIMARY KEY,
  purchase_order_id bigint NOT NULL,
  po_line_id bigint,
  supplier_invoice_id bigint,
  action text NOT NULL,                 -- edit / add / delete / ignore
  item_key text,                        -- for ignore: which difference was let go
  old_values jsonb, new_values jsonb, reason text,
  changed_by bigint, changed_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS po_line_changes_po ON public.po_line_changes (purchase_order_id, changed_at DESC);
CREATE INDEX IF NOT EXISTS po_line_changes_inv ON public.po_line_changes (supplier_invoice_id);
ALTER TABLE public.po_line_changes ENABLE ROW LEVEL SECURITY;

-- p_changes: [{id, quantity, unit_cost, description}] edits a line, [{id, delete: true}] removes one, [{quantity, unit_cost, description}] adds one,
-- [{ignore: "key", note}] records a difference you chose to leave. p_check: mark the invoice checked when done.
CREATE OR REPLACE FUNCTION public.po_lines_apply(p_invoice bigint, p_changes jsonb, p_check boolean DEFAULT false, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i supplier_invoices; v_po bigint; v_job bigint; x jsonb; l record; v_new bigint; v_n int := 0; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change POs'; END IF;
  SELECT * INTO i FROM supplier_invoices WHERE id = p_invoice; IF i.id IS NULL THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
  v_po := public._sinv_po(i); IF v_po IS NULL THEN RAISE EXCEPTION 'This invoice isn''t matched to a PO yet'; END IF;
  SELECT job_id INTO v_job FROM purchase_orders WHERE id = v_po;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p_changes, '[]')) LOOP
    IF x ? 'ignore' THEN
      INSERT INTO po_line_changes (purchase_order_id, supplier_invoice_id, action, item_key, reason, changed_by)
      VALUES (v_po, p_invoice, 'ignore', x ->> 'ignore', coalesce(nullif(x ->> 'note', ''), p_reason), v_me); v_n := v_n + 1; CONTINUE; END IF;
    IF x ? 'id' THEN
      SELECT * INTO l FROM purchase_order_lines WHERE id = (x ->> 'id')::bigint AND purchase_order_id = v_po;
      IF l.id IS NULL THEN RAISE EXCEPTION 'That PO line is gone. Refresh the page.'; END IF;
      IF coalesce((x ->> 'delete')::boolean, false) THEN
        IF EXISTS (SELECT 1 FROM po_receipt_lines r WHERE r.purchase_order_line_id = l.id) THEN RAISE EXCEPTION 'Line "%" was already received, so it can''t be taken off. Set its quantity instead.', l.description; END IF;
        DELETE FROM purchase_order_lines WHERE id = l.id;
        INSERT INTO po_line_changes (purchase_order_id, po_line_id, supplier_invoice_id, action, old_values, reason, changed_by)
        VALUES (v_po, l.id, p_invoice, 'delete', jsonb_build_object('description', l.description, 'quantity', l.quantity, 'unit_cost', l.unit_cost), p_reason, v_me);
      ELSE
        IF (x ? 'quantity' AND (x ->> 'quantity')::numeric IS DISTINCT FROM l.quantity) OR (x ? 'unit_cost' AND (x ->> 'unit_cost')::numeric IS DISTINCT FROM l.unit_cost)
           OR (x ? 'description' AND nullif(btrim(x ->> 'description'), '') IS DISTINCT FROM l.description) THEN
          UPDATE purchase_order_lines SET quantity = CASE WHEN x ? 'quantity' THEN (x ->> 'quantity')::numeric ELSE quantity END,
            unit_cost = CASE WHEN x ? 'unit_cost' THEN (x ->> 'unit_cost')::numeric ELSE unit_cost END,
            description = CASE WHEN x ? 'description' AND nullif(btrim(x ->> 'description'), '') IS NOT NULL THEN btrim(x ->> 'description') ELSE description END
          WHERE id = l.id;
          INSERT INTO po_line_changes (purchase_order_id, po_line_id, supplier_invoice_id, action, old_values, new_values, reason, changed_by)
          VALUES (v_po, l.id, p_invoice, 'edit', jsonb_build_object('description', l.description, 'quantity', l.quantity, 'unit_cost', l.unit_cost),
                  (SELECT jsonb_build_object('description', description, 'quantity', quantity, 'unit_cost', unit_cost) FROM purchase_order_lines WHERE id = l.id), p_reason, v_me);
        ELSE CONTINUE; END IF;
      END IF;
    ELSE
      IF nullif(btrim(x ->> 'description'), '') IS NULL THEN RAISE EXCEPTION 'A new line needs a description'; END IF;
      INSERT INTO purchase_order_lines (purchase_order_id, description, quantity, unit_cost, quantity_received, job_id)
      VALUES (v_po, btrim(x ->> 'description'), coalesce((x ->> 'quantity')::numeric, 1), coalesce((x ->> 'unit_cost')::numeric, 0), 0, v_job) RETURNING id INTO v_new;
      INSERT INTO po_line_changes (purchase_order_id, po_line_id, supplier_invoice_id, action, new_values, reason, changed_by)
      VALUES (v_po, v_new, p_invoice, 'add', jsonb_build_object('description', btrim(x ->> 'description'), 'quantity', coalesce((x ->> 'quantity')::numeric, 1), 'unit_cost', coalesce((x ->> 'unit_cost')::numeric, 0)), p_reason, v_me);
    END IF;
    v_n := v_n + 1;
  END LOOP;
  IF p_check THEN UPDATE supplier_invoices SET match_state = 'ok', matched_by = v_me, matched_at = now(), updated_at = now() WHERE id = p_invoice; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('purchase_orders', v_po, 'update', v_me, jsonb_build_object('po_lines_from_invoice', i.supplier_invoice_number, 'changes', p_changes, 'checked', p_check));
  RETURN jsonb_build_object('changed', v_n);
END $function$;
REVOKE EXECUTE ON FUNCTION public.po_lines_apply(bigint, jsonb, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.po_lines_apply(bigint, jsonb, boolean, text) TO authenticated;

-- the invoice's detail now also gives each PO line's id, the PO's change history and the differences let go on this invoice
CREATE OR REPLACE FUNCTION public.supplier_invoice_get(p_id bigint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i supplier_invoices; v_po bigint;
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  SELECT * INTO i FROM supplier_invoices WHERE id = p_id; IF i.id IS NULL THEN RAISE EXCEPTION 'Not found'; END IF;
  v_po := public._sinv_po(i);
  RETURN jsonb_build_object('lines', i.lines,
    'po_lines', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', pl.id, 'description', pl.description, 'quantity', pl.quantity, 'unit_cost', pl.unit_cost, 'line_total', pl.line_total,
                   'received', pl.quantity_received, 'sku', pi.sku) ORDER BY pl.id), '[]') FROM purchase_order_lines pl LEFT JOIN pricebook_items pi ON pi.id = pl.item_id WHERE pl.purchase_order_id = v_po),
    'pages', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'page_no', d.page_no) ORDER BY d.page_no), '[]') FROM supplier_doc_pages d WHERE d.supplier_invoice_id = p_id),
    'po_st', (SELECT st_id IS NOT NULL FROM purchase_orders WHERE id = v_po),
    'ignored', (SELECT coalesce(jsonb_agg(DISTINCT c.item_key), '[]') FROM po_line_changes c WHERE c.supplier_invoice_id = p_id AND c.action = 'ignore'),
    'changes', (SELECT coalesce(jsonb_agg(jsonb_build_object('at', c.changed_at, 'action', c.action, 'old', c.old_values, 'new', c.new_values, 'key', c.item_key, 'reason', c.reason,
                   'invoice', (SELECT supplier_invoice_number FROM supplier_invoices s WHERE s.id = c.supplier_invoice_id),
                   'by', (SELECT public._emp_name(u.employee_id) FROM app_users u WHERE u.id = c.changed_by)) ORDER BY c.changed_at DESC), '[]')
                FROM po_line_changes c WHERE c.purchase_order_id = v_po));
END $function$;
NOTIFY pgrst, 'reload schema';

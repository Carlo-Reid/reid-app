-- Supplier invoices: pair an invoice line with a PO line by hand ("same part, labelled differently"), and add a line to the
-- invoice that the reader missed. The PO's model numbers are sent too, so a line is also paired by the model number on the PO.
CREATE TABLE IF NOT EXISTS public.supplier_invoice_pairs (
  supplier_invoice_id bigint NOT NULL, inv_key text NOT NULL, po_line_id bigint NOT NULL,
  paired_by bigint, paired_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (supplier_invoice_id, inv_key));
ALTER TABLE public.supplier_invoice_pairs ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.supplier_invoice_get(p_id bigint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i supplier_invoices; v_po bigint;
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  SELECT * INTO i FROM supplier_invoices WHERE id = p_id; IF i.id IS NULL THEN RAISE EXCEPTION 'Not found'; END IF;
  v_po := public._sinv_po(i);
  RETURN jsonb_build_object('lines', i.lines,
    'po_lines', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', pl.id, 'description', pl.description, 'quantity', pl.quantity, 'unit_cost', pl.unit_cost, 'line_total', pl.line_total,
                   'received', pl.quantity_received, 'sku', pi.sku, 'model', pi.model_number) ORDER BY pl.id), '[]') FROM purchase_order_lines pl LEFT JOIN pricebook_items pi ON pi.id = pl.item_id WHERE pl.purchase_order_id = v_po),
    'pages', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'page_no', d.page_no) ORDER BY d.page_no), '[]') FROM supplier_doc_pages d WHERE d.supplier_invoice_id = p_id),
    'po_st', (SELECT st_id IS NOT NULL FROM purchase_orders WHERE id = v_po),
    'pairs', (SELECT coalesce(jsonb_agg(jsonb_build_object('inv_key', p.inv_key, 'po_line_id', p.po_line_id, 'by', (SELECT public._emp_name(u.employee_id) FROM app_users u WHERE u.id = p.paired_by))), '[]')
              FROM supplier_invoice_pairs p WHERE p.supplier_invoice_id = p_id),
    'ignored', (SELECT coalesce(jsonb_agg(DISTINCT c.item_key), '[]') FROM po_line_changes c WHERE c.supplier_invoice_id = p_id AND c.action = 'ignore'),
    'changes', (SELECT coalesce(jsonb_agg(jsonb_build_object('at', c.changed_at, 'action', c.action, 'old', c.old_values, 'new', c.new_values, 'key', c.item_key, 'reason', c.reason,
                   'invoice', (SELECT supplier_invoice_number FROM supplier_invoices s WHERE s.id = c.supplier_invoice_id),
                   'by', (SELECT public._emp_name(u.employee_id) FROM app_users u WHERE u.id = c.changed_by)) ORDER BY c.changed_at DESC), '[]')
                FROM po_line_changes c WHERE c.purchase_order_id = v_po));
END $function$;

-- p_po_line null: undo the pairing
CREATE OR REPLACE FUNCTION public.sinv_pair_set(p_invoice bigint, p_inv_key text, p_po_line bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF p_po_line IS NULL THEN DELETE FROM supplier_invoice_pairs WHERE supplier_invoice_id = p_invoice AND inv_key = p_inv_key;
  ELSE INSERT INTO supplier_invoice_pairs (supplier_invoice_id, inv_key, po_line_id, paired_by) VALUES (p_invoice, p_inv_key, p_po_line, public.current_app_user_id())
       ON CONFLICT (supplier_invoice_id, inv_key) DO UPDATE SET po_line_id = EXCLUDED.po_line_id, paired_by = EXCLUDED.paired_by, paired_at = now(); END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoices', p_invoice, 'update', public.current_app_user_id(), jsonb_build_object('paired', p_inv_key, 'po_line', p_po_line));
END $function$;

-- a line the reader missed: {code, description, shipped, unit_price, net_amount}; marked as typed in by hand. p_remove: take a typed-in line off again (by its place)
CREATE OR REPLACE FUNCTION public.sinv_line_add(p_invoice bigint, p_line jsonb, p_remove int DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE L jsonb;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  SELECT coalesce(lines, '[]') INTO L FROM supplier_invoices WHERE id = p_invoice; IF L IS NULL THEN RAISE EXCEPTION 'Not found'; END IF;
  IF p_remove IS NOT NULL THEN
    IF NOT coalesce((L -> p_remove ->> 'by_hand')::boolean, false) THEN RAISE EXCEPTION 'Only lines typed in by hand can be taken off'; END IF;
    UPDATE supplier_invoices SET lines = L - p_remove, updated_at = now() WHERE id = p_invoice;
  ELSE
    UPDATE supplier_invoices SET lines = L || jsonb_build_array(p_line || jsonb_build_object('by_hand', true, 'added_by', public.current_app_user_id(), 'added_at', now())), updated_at = now() WHERE id = p_invoice;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoices', p_invoice, 'update', public.current_app_user_id(), jsonb_build_object('line_added', p_line, 'line_removed', p_remove));
END $function$;
REVOKE EXECUTE ON FUNCTION public.sinv_pair_set(bigint, text, bigint), public.sinv_line_add(bigint, jsonb, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sinv_pair_set(bigint, text, bigint), public.sinv_line_add(bigint, jsonb, int) TO authenticated;
NOTIFY pgrst, 'reload schema';

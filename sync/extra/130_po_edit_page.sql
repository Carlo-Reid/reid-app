-- POs page: a PO opens as its own page where everything can be changed: status, supplier, what it's for, dates, the supplier's #,
-- what it came to, and its lines (change, add, take off). Every line change is recorded (Changes to this PO), and a PO
-- whose lines were changed here keeps them: ServiceTitan's sync doesn't put its old lines back.
CREATE OR REPLACE FUNCTION public._po_can_edit() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.current_staff_role() = 'owner' OR public.has_permission('po.create') $$;

CREATE OR REPLACE FUNCTION public.po_full_get(p_id bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE po purchase_orders;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  SELECT * INTO po FROM purchase_orders WHERE id = p_id; IF po.id IS NULL THEN RAISE EXCEPTION 'That PO isn''t in the app'; END IF;
  RETURN jsonb_build_object('id', po.id, 'po_number', po.po_number, 'status', po.status, 'supplier_id', po.supplier_id, 'supplier', (SELECT btrim(name) FROM suppliers WHERE id = po.supplier_id),
    'purpose', po.purpose, 'job_id', po.job_id, 'job_number', (SELECT job_number FROM jobs WHERE id = po.job_id),
    'customer_id', (SELECT customer_id FROM jobs WHERE id = po.job_id), 'customer_name', (SELECT c.display_name FROM jobs j JOIN customers c ON c.id = j.customer_id WHERE j.id = po.job_id),
    'description', po.description, 'notes', po.notes, 'ordered_at', po.ordered_at, 'created_at', po.created_at, 'expected_on', po.expected_on,
    'supplier_reference', po.supplier_reference, 'amount', po.amount, 'from_st', po.st_id IS NOT NULL, 'can_edit', public._po_can_edit(),
    'tech', public._emp_name(po.ordered_by_employee_id),
    'lines', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'description', l.description, 'quantity', l.quantity, 'unit_cost', l.unit_cost, 'line_total', l.line_total,
                'received', l.quantity_received, 'locked', EXISTS (SELECT 1 FROM po_receipt_lines r WHERE r.purchase_order_line_id = l.id)) ORDER BY l.id), '[]') FROM purchase_order_lines l WHERE l.purchase_order_id = po.id),
    'changes', (SELECT coalesce(jsonb_agg(jsonb_build_object('action', c.action, 'old', c.old_values, 'new', c.new_values, 'reason', c.reason, 'at', c.changed_at,
                'by', public._emp_name((SELECT u.employee_id FROM app_users u WHERE u.id = c.changed_by))) ORDER BY c.changed_at DESC), '[]')
                FROM (SELECT * FROM po_line_changes WHERE purchase_order_id = po.id AND action <> 'ignore' ORDER BY changed_at DESC LIMIT 50) c),
    'invoices', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.supplier_invoice_number, 'date', i.invoice_date, 'total', i.total) ORDER BY i.invoice_date), '[]')
                 FROM supplier_invoices i WHERE public._sinv_po(i) = po.id));
END $function$;

-- p: the PO's own fields (only the ones sent are changed); p_lines: [{id, description, quantity, unit_cost}] changes a line,
-- [{id, delete: true}] takes one off, [{description, quantity, unit_cost}] adds one
CREATE OR REPLACE FUNCTION public.po_full_save(p_id bigint, p jsonb, p_lines jsonb DEFAULT '[]', p_reason text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE po purchase_orders; x jsonb; l purchase_order_lines; v_new bigint; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT public._po_can_edit() THEN RAISE EXCEPTION 'You need "Create POs" to change POs'; END IF;
  SELECT * INTO po FROM purchase_orders WHERE id = p_id; IF po.id IS NULL THEN RAISE EXCEPTION 'That PO isn''t in the app'; END IF;
  UPDATE purchase_orders SET
    status = CASE WHEN p ? 'status' THEN coalesce(nullif(p ->> 'status', ''), status) ELSE status END,
    supplier_id = CASE WHEN p ? 'supplier_id' AND nullif(p ->> 'supplier_id', '') IS NOT NULL THEN (p ->> 'supplier_id')::bigint ELSE supplier_id END,
    description = CASE WHEN p ? 'description' THEN nullif(btrim(p ->> 'description'), '') ELSE description END,
    notes = CASE WHEN p ? 'notes' THEN nullif(btrim(p ->> 'notes'), '') ELSE notes END,
    expected_on = CASE WHEN p ? 'expected_on' THEN nullif(p ->> 'expected_on', '')::date ELSE expected_on END,
    supplier_reference = CASE WHEN p ? 'supplier_reference' THEN nullif(btrim(p ->> 'supplier_reference'), '') ELSE supplier_reference END,
    amount = CASE WHEN p ? 'amount' THEN nullif(p ->> 'amount', '')::numeric ELSE amount END
  WHERE id = p_id;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p_lines, '[]')) LOOP
    IF x ? 'id' AND nullif(x ->> 'id', '') IS NOT NULL THEN
      SELECT * INTO l FROM purchase_order_lines WHERE id = (x ->> 'id')::bigint AND purchase_order_id = p_id; IF l.id IS NULL THEN CONTINUE; END IF;
      IF coalesce((x ->> 'delete')::boolean, false) THEN
        IF EXISTS (SELECT 1 FROM po_receipt_lines r WHERE r.purchase_order_line_id = l.id) THEN RAISE EXCEPTION 'Line "%" was already received, so it can''t be taken off. Change its quantity instead.', l.description; END IF;
        DELETE FROM purchase_order_lines WHERE id = l.id;
        INSERT INTO po_line_changes (purchase_order_id, po_line_id, action, old_values, reason, changed_by)
        VALUES (p_id, l.id, 'delete', jsonb_build_object('description', l.description, 'quantity', l.quantity, 'unit_cost', l.unit_cost), p_reason, v_me);
      ELSIF btrim(coalesce(x ->> 'description', l.description)) IS DISTINCT FROM l.description OR coalesce((x ->> 'quantity')::numeric, l.quantity) IS DISTINCT FROM l.quantity
            OR coalesce((x ->> 'unit_cost')::numeric, l.unit_cost) IS DISTINCT FROM l.unit_cost THEN
        UPDATE purchase_order_lines SET description = btrim(coalesce(x ->> 'description', description)), quantity = coalesce((x ->> 'quantity')::numeric, quantity),
               unit_cost = coalesce((x ->> 'unit_cost')::numeric, unit_cost) WHERE id = l.id;
        INSERT INTO po_line_changes (purchase_order_id, po_line_id, action, old_values, new_values, reason, changed_by)
        VALUES (p_id, l.id, 'edit', jsonb_build_object('description', l.description, 'quantity', l.quantity, 'unit_cost', l.unit_cost),
                (SELECT jsonb_build_object('description', description, 'quantity', quantity, 'unit_cost', unit_cost) FROM purchase_order_lines WHERE id = l.id), p_reason, v_me);
      END IF;
    ELSIF btrim(coalesce(x ->> 'description', '')) <> '' OR coalesce((x ->> 'unit_cost')::numeric, 0) <> 0 THEN
      INSERT INTO purchase_order_lines (purchase_order_id, description, quantity, unit_cost, quantity_received, job_id)
      VALUES (p_id, btrim(coalesce(x ->> 'description', 'Item')), coalesce((x ->> 'quantity')::numeric, 1), coalesce((x ->> 'unit_cost')::numeric, 0), 0, po.job_id)
      RETURNING id INTO v_new;
      INSERT INTO po_line_changes (purchase_order_id, po_line_id, action, new_values, reason, changed_by)
      VALUES (p_id, v_new, 'add', jsonb_build_object('description', btrim(coalesce(x ->> 'description', 'Item')), 'quantity', coalesce((x ->> 'quantity')::numeric, 1), 'unit_cost', coalesce((x ->> 'unit_cost')::numeric, 0)), p_reason, v_me);
    END IF;
  END LOOP;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('purchase_orders', p_id, 'update', v_me, jsonb_build_object('po_page', p, 'lines', p_lines, 'reason', p_reason));
END $function$;
REVOKE EXECUTE ON FUNCTION public._po_can_edit(), public.po_full_get(bigint), public.po_full_save(bigint, jsonb, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._po_can_edit(), public.po_full_get(bigint), public.po_full_save(bigint, jsonb, jsonb, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

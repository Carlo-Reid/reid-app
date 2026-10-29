-- Supplier invoices: items billed that weren't on the PO can be sent back. A return holds those items (what, qty, price each),
-- the supplier, the PO and the invoice they came from, and where it stands: to send back, sent back, credit received, cancelled.
-- Every step is recorded (po_line_changes action 'return' and audit_log).
CREATE TABLE IF NOT EXISTS public.supplier_returns (
  id bigserial PRIMARY KEY,
  supplier_id bigint, purchase_order_id bigint, supplier_invoice_id bigint,
  status text NOT NULL DEFAULT 'open',        -- open (to send back) / sent / credited / cancelled
  note text, ra_number text, credit_invoice_id bigint,
  created_by bigint, created_at timestamptz NOT NULL DEFAULT now(), updated_by bigint, updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.supplier_return_lines (
  id bigserial PRIMARY KEY,
  return_id bigint NOT NULL REFERENCES public.supplier_returns(id) ON DELETE CASCADE,
  item_key text, code text, description text NOT NULL, quantity numeric NOT NULL DEFAULT 1, unit_cost numeric NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS supplier_returns_inv ON public.supplier_returns (supplier_invoice_id);
CREATE INDEX IF NOT EXISTS supplier_return_lines_r ON public.supplier_return_lines (return_id);
ALTER TABLE public.supplier_returns ENABLE ROW LEVEL SECURITY; ALTER TABLE public.supplier_return_lines ENABLE ROW LEVEL SECURITY;

-- p_items: [{key, code, description, quantity, unit_cost}] (the invoice lines that weren't on the PO). Adds to this invoice's open return, or starts one.
CREATE OR REPLACE FUNCTION public.supplier_return_add(p_invoice bigint, p_items jsonb, p_note text DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i supplier_invoices; v_po bigint; v_r bigint; x jsonb; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to do returns'; END IF;
  SELECT * INTO i FROM supplier_invoices WHERE id = p_invoice; IF i.id IS NULL THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'Pick what to send back'; END IF;
  v_po := public._sinv_po(i);
  SELECT id INTO v_r FROM supplier_returns WHERE supplier_invoice_id = p_invoice AND status = 'open' ORDER BY id DESC LIMIT 1;
  IF v_r IS NULL THEN
    INSERT INTO supplier_returns (supplier_id, purchase_order_id, supplier_invoice_id, note, created_by, updated_by)
    VALUES (i.supplier_id, v_po, p_invoice, nullif(btrim(coalesce(p_note, '')), ''), v_me, v_me) RETURNING id INTO v_r;
  END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    CONTINUE WHEN EXISTS (SELECT 1 FROM supplier_return_lines l JOIN supplier_returns r ON r.id = l.return_id
                          WHERE r.supplier_invoice_id = p_invoice AND r.status <> 'cancelled' AND l.item_key = x ->> 'key');
    INSERT INTO supplier_return_lines (return_id, item_key, code, description, quantity, unit_cost)
    VALUES (v_r, x ->> 'key', nullif(x ->> 'code', ''), coalesce(nullif(btrim(x ->> 'description'), ''), 'Item'), coalesce((x ->> 'quantity')::numeric, 1), coalesce((x ->> 'unit_cost')::numeric, 0));
    IF v_po IS NOT NULL THEN
      INSERT INTO po_line_changes (purchase_order_id, supplier_invoice_id, action, item_key, new_values, reason, changed_by)
      VALUES (v_po, p_invoice, 'return', x ->> 'key', x, nullif(btrim(coalesce(p_note, '')), ''), v_me);
    END IF;
  END LOOP;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('supplier_returns', v_r, 'update', v_me, jsonb_build_object('invoice', i.supplier_invoice_number, 'items', p_items));
  RETURN v_r;
END $function$;

-- move a return along: sent back (with the supplier's RA number), credit received, or cancelled; or take one item off it
CREATE OR REPLACE FUNCTION public.supplier_return_set(p_id bigint, p jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to do returns'; END IF;
  IF NOT EXISTS (SELECT 1 FROM supplier_returns WHERE id = p_id) THEN RAISE EXCEPTION 'That return is gone'; END IF;
  IF p ? 'status' THEN
    IF p ->> 'status' NOT IN ('open', 'sent', 'credited', 'cancelled') THEN RAISE EXCEPTION 'Unknown status'; END IF;
    UPDATE supplier_returns SET status = p ->> 'status', updated_by = v_me, updated_at = now() WHERE id = p_id; END IF;
  IF p ? 'ra_number' THEN UPDATE supplier_returns SET ra_number = nullif(btrim(p ->> 'ra_number'), ''), updated_by = v_me, updated_at = now() WHERE id = p_id; END IF;
  IF p ? 'note' THEN UPDATE supplier_returns SET note = nullif(btrim(p ->> 'note'), ''), updated_by = v_me, updated_at = now() WHERE id = p_id; END IF;
  IF p ? 'remove_line' THEN DELETE FROM supplier_return_lines WHERE id = (p ->> 'remove_line')::bigint AND return_id = p_id; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('supplier_returns', p_id, 'update', v_me, p);
END $function$;

-- returns: one invoice's (p_invoice), or every one still open or sent (p_invoice null)
CREATE OR REPLACE FUNCTION public.supplier_returns_list(p_invoice bigint DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN NOT public._can_see_costs() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object(
    'id', r.id, 'status', r.status, 'note', r.note, 'ra', r.ra_number, 'at', r.created_at, 'updated', r.updated_at,
    'supplier', (SELECT name FROM suppliers s WHERE s.id = r.supplier_id), 'invoice_id', r.supplier_invoice_id,
    'invoice', (SELECT supplier_invoice_number FROM supplier_invoices x WHERE x.id = r.supplier_invoice_id),
    'po', (SELECT po_number FROM purchase_orders p WHERE p.id = r.purchase_order_id),
    'by', (SELECT public._emp_name(u.employee_id) FROM app_users u WHERE u.id = r.created_by),
    'lines', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'key', l.item_key, 'code', l.code, 'description', l.description, 'quantity', l.quantity, 'unit_cost', l.unit_cost) ORDER BY l.id), '[]') FROM supplier_return_lines l WHERE l.return_id = r.id),
    'total', (SELECT round(coalesce(sum(l.quantity * l.unit_cost), 0), 2) FROM supplier_return_lines l WHERE l.return_id = r.id)) ORDER BY r.created_at DESC)
    FROM supplier_returns r WHERE (p_invoice IS NULL AND r.status IN ('open', 'sent')) OR r.supplier_invoice_id = p_invoice), '[]'::jsonb) END
$function$;
REVOKE EXECUTE ON FUNCTION public.supplier_return_add(bigint, jsonb, text), public.supplier_return_set(bigint, jsonb), public.supplier_returns_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_return_add(bigint, jsonb, text), public.supplier_return_set(bigint, jsonb), public.supplier_returns_list(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Vista installs: the tank's P.O., made from the customer's invoice, and (when Vista pays for the tank) a Credit Order
-- that waits for the supplier's credit to come back. (Carlo, Nov 11, 2026)
-- One row = one tank on one invoice: the invoice line, who pays (reid | partner), the supplier, the PO made for it,
-- and for "partner" the credit order (CO-<id>): waiting -> received (or cancelled).
CREATE TABLE IF NOT EXISTS public.tank_orders (
  id bigserial PRIMARY KEY,
  invoice_id bigint NOT NULL, job_id bigint, invoice_line_id bigint, item_id bigint,
  description text NOT NULL, quantity numeric NOT NULL DEFAULT 1, unit_cost numeric NOT NULL DEFAULT 0,
  payer text NOT NULL CHECK (payer IN ('reid', 'partner')),
  supplier_id bigint, purchase_order_id bigint,
  credit_number text, credit_status text CHECK (credit_status IN ('waiting', 'received', 'cancelled')),
  credit_amount numeric, credit_ref text, credit_received_at timestamptz, credit_received_by bigint,
  created_by bigint, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS tank_orders_inv ON public.tank_orders (invoice_id);
CREATE INDEX IF NOT EXISTS tank_orders_wait ON public.tank_orders (credit_status) WHERE credit_status = 'waiting';
ALTER TABLE public.tank_orders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tank_orders FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._tank_office() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT public.current_staff_role() IN ('owner', 'admin', 'office', 'dispatcher', 'accounting') OR public.has_permission('po.create') $function$;

-- what the bottom of the invoice shows: who pays, the tank P.O.s made, and the invoice lines a tank can be picked from
CREATE OR REPLACE FUNCTION public.tank_order_for(p_invoice bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i invoices; j jobs; v_cost boolean := public._can_see_costs();
BEGIN
  SELECT * INTO i FROM invoices WHERE id = p_invoice; IF i.id IS NULL THEN RETURN NULL; END IF;
  IF NOT (public._can_invoice(i.job_id) OR public._tank_office()) THEN RETURN NULL; END IF;
  SELECT * INTO j FROM jobs WHERE id = i.job_id;
  RETURN jsonb_build_object('payer', j.tank_payer, 'job', j.job_number, 'office', public._tank_office(),
    'orders', coalesce((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'line', t.invoice_line_id, 'description', t.description, 'quantity', t.quantity,
        'unit_cost', CASE WHEN v_cost THEN t.unit_cost END, 'payer', t.payer, 'supplier', btrim(s.name), 'po_id', t.purchase_order_id, 'po_number', po.po_number,
        'po_status', po.status, 'credit_number', t.credit_number, 'credit_status', t.credit_status, 'credit_amount', CASE WHEN v_cost THEN t.credit_amount END,
        'credit_ref', t.credit_ref, 'credit_received_at', t.credit_received_at, 'credit_auto', (t.credit_status = 'received' AND t.credit_received_by IS NULL), 'created_at', t.created_at) ORDER BY t.id)
      FROM tank_orders t LEFT JOIN suppliers s ON s.id = t.supplier_id LEFT JOIN purchase_orders po ON po.id = t.purchase_order_id WHERE t.invoice_id = i.id), '[]'::jsonb),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('id', l.id, 'item_id', l.item_id, 'description', l.description, 'sku', pi.sku, 'kind', pi.item_type,
        'quantity', l.quantity, 'unit_cost', CASE WHEN v_cost THEN coalesce(l.unit_cost, pi.unit_cost) END,
        'tankish', (pi.item_type = 'equipment' OR l.description ~* 'tank|water heater')) ORDER BY l.sequence, l.id)
      FROM invoice_lines l LEFT JOIN pricebook_items pi ON pi.id = l.item_id
      WHERE l.invoice_id = i.id AND l.kit_parent_line_id IS NULL AND l.item_id IS NOT NULL AND l.quantity > 0
        AND NOT EXISTS (SELECT 1 FROM tank_orders t WHERE t.invoice_line_id = l.id)), '[]'::jsonb));
END $function$;

-- make the tank's P.O. from an invoice line; when Vista pays, also the Credit Order that waits for the supplier's credit
CREATE OR REPLACE FUNCTION public.tank_order_make(p_invoice bigint, p_line bigint, p_supplier bigint, p_supplier_name text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i invoices; j jobs; l invoice_lines; v jsonb; v_po bigint; v_sup bigint; v_cost numeric; v_id bigint; v_co text; v_me bigint := public.current_app_user_id();
BEGIN
  SELECT * INTO i FROM invoices WHERE id = p_invoice; IF i.id IS NULL THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
  IF i.job_id IS NULL THEN RAISE EXCEPTION 'This invoice has no job, so I can not make a P.O. for it'; END IF;
  IF NOT (public._can_invoice(i.job_id) OR public._tank_office()) THEN RAISE EXCEPTION 'You can only do this on the jobs you are on'; END IF;
  SELECT * INTO j FROM jobs WHERE id = i.job_id;
  IF j.tank_payer IS NULL OR j.tank_payer NOT IN ('reid', 'partner') THEN RAISE EXCEPTION 'First pick who pays for the tank: us or Vista'; END IF;
  SELECT * INTO l FROM invoice_lines WHERE id = p_line AND invoice_id = i.id;
  IF l.id IS NULL THEN RAISE EXCEPTION 'Pick the tank on the invoice first'; END IF;
  IF EXISTS (SELECT 1 FROM tank_orders WHERE invoice_line_id = l.id) THEN RAISE EXCEPTION 'This tank already has a P.O.'; END IF;
  v_cost := coalesce(l.unit_cost, (SELECT unit_cost FROM pricebook_items WHERE id = l.item_id), 0);
  v := public.get_po_number(j.id, p_supplier, p_supplier_name, left('Tank: ' || coalesce(l.description, ''), 200));
  v_po := (v ->> 'id')::bigint; SELECT supplier_id INTO v_sup FROM purchase_orders WHERE id = v_po;
  INSERT INTO purchase_order_lines (purchase_order_id, item_id, description, quantity, unit_cost, quantity_received, job_id)
  VALUES (v_po, l.item_id, left(coalesce(l.description, 'Tank'), 500), l.quantity, v_cost, 0, j.id);
  INSERT INTO tank_orders (invoice_id, job_id, invoice_line_id, item_id, description, quantity, unit_cost, payer, supplier_id, purchase_order_id, created_by)
  VALUES (i.id, j.id, l.id, l.item_id, coalesce(l.description, 'Tank'), l.quantity, v_cost, j.tank_payer, v_sup, v_po, v_me) RETURNING id INTO v_id;
  IF j.tank_payer = 'partner' THEN
    v_co := 'CO-' || v_id;
    UPDATE tank_orders SET credit_number = v_co, credit_status = 'waiting', credit_amount = round(l.quantity * v_cost, 2) WHERE id = v_id;
    INSERT INTO notes (entity_type, entity_id, body, author_user_id, source)
    VALUES ('job', j.id, 'Credit Order ' || v_co || ': waiting for the credit from ' || (v ->> 'supplier') || ' for the tank on PO ' || (v ->> 'po_number') || ' (Vista pays for the tank).', v_me, 'po');
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('tank_orders', v_id, 'insert', v_me, jsonb_build_object('invoice', i.invoice_number, 'po', v ->> 'po_number', 'payer', j.tank_payer, 'credit_order', v_co));
  RETURN jsonb_build_object('id', v_id, 'po_id', v_po, 'po_number', v ->> 'po_number', 'supplier', v ->> 'supplier', 'credit_number', v_co);
END $function$;

-- the credit came back (received), put it back to waiting, or cancel the credit order
CREATE OR REPLACE FUNCTION public.tank_credit_set(p_id bigint, p_action text, p_ref text DEFAULT NULL, p_amount numeric DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE t tank_orders; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT public._tank_office() THEN RAISE EXCEPTION 'Only office people and owners can change a credit order'; END IF;
  SELECT * INTO t FROM tank_orders WHERE id = p_id; IF t.id IS NULL OR t.credit_number IS NULL THEN RAISE EXCEPTION 'That credit order is gone'; END IF;
  IF p_action = 'received' THEN
    UPDATE tank_orders SET credit_status = 'received', credit_ref = nullif(btrim(coalesce(p_ref, '')), ''), credit_amount = coalesce(p_amount, credit_amount),
      credit_received_at = now(), credit_received_by = v_me WHERE id = p_id;
  ELSIF p_action = 'waiting' THEN
    UPDATE tank_orders SET credit_status = 'waiting', credit_ref = NULL, credit_received_at = NULL, credit_received_by = NULL WHERE id = p_id;
  ELSIF p_action = 'cancel' THEN
    UPDATE tank_orders SET credit_status = 'cancelled' WHERE id = p_id;
  ELSE RAISE EXCEPTION 'I do not know that step'; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('tank_orders', p_id, 'update', v_me, jsonb_build_object('credit_order', t.credit_number, 'step', p_action, 'ref', p_ref, 'amount', p_amount));
END $function$;

-- Tasks page: the credit orders still waiting on a supplier (office people and owners)
CREATE OR REPLACE FUNCTION public.tank_credits_waiting() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN NOT public._tank_office() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'credit_number', t.credit_number,
      'supplier', btrim(s.name), 'po_id', t.purchase_order_id, 'po_number', po.po_number, 'invoice_id', t.invoice_id, 'invoice', i.invoice_number,
      'customer_id', i.customer_id, 'customer', c.display_name, 'description', t.description,
      'amount', CASE WHEN public._can_see_costs() THEN t.credit_amount END, 'since', t.created_at) ORDER BY t.created_at)
    FROM tank_orders t JOIN invoices i ON i.id = t.invoice_id LEFT JOIN customers c ON c.id = i.customer_id
      LEFT JOIN suppliers s ON s.id = t.supplier_id LEFT JOIN purchase_orders po ON po.id = t.purchase_order_id
    WHERE t.credit_status = 'waiting'), '[]'::jsonb) END $function$;

REVOKE EXECUTE ON FUNCTION public._tank_office(), public.tank_order_for(bigint), public.tank_order_make(bigint, bigint, bigint, text),
  public.tank_credit_set(bigint, text, text, numeric), public.tank_credits_waiting() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._tank_office(), public.tank_order_for(bigint), public.tank_order_make(bigint, bigint, bigint, text),
  public.tank_credit_set(bigint, text, text, numeric), public.tank_credits_waiting() TO authenticated;
NOTIFY pgrst, 'reload schema';

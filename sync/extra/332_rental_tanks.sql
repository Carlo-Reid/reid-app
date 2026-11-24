-- Rental tanks: one line for each tank, with every paper it needs, so the whole thing can be tracked in one place.
-- (Carlo, Nov 24, 2026: "there needs to be a way to track it all and understand it all".)
-- A tank's papers: our invoice (the partner pays us the allowance) -> the P.O. (we order the tank) -> the supplier's invoice
-- (we pay the supplier) -> the Credit Order (we wait) -> the supplier's credit / Credit Memo (the tank's money comes back) -> we are paid.
-- Two kinds of line: 'app' = a tank whose P.O. was made on the invoice page (tank_orders); 'old' = an older tank brought in by its
-- supplier invoice (rental_tank_old), from before the app made the P.O. and the Credit Order.
CREATE TABLE IF NOT EXISTS public.rental_tank_old (
  supplier_invoice_id bigint PRIMARY KEY, note text, added_by bigint, added_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.rental_tank_old ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.rental_tank_old FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._rt_num(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  SELECT regexp_replace(upper(coalesce(t, '')), '[^A-Z0-9]', '', 'g') $function$;

-- every tank (p_job null), or the tanks of one job (the strip on that job's invoice)
CREATE OR REPLACE FUNCTION public.rental_tanks(p_job bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_cost boolean := public._can_see_costs(); v jsonb;
BEGIN
  IF NOT public._tank_office() THEN RETURN jsonb_build_object('ok', false, 'rows', '[]'::jsonb); END IF;
  WITH base AS (
    SELECT 'a' || t.id AS key, 'app'::text AS src, t.id AS tank_order_id, t.job_id, t.invoice_id, t.supplier_id, t.purchase_order_id AS po_id,
      t.description, t.quantity * t.unit_cost AS cost, t.payer, t.credit_number, t.credit_status, t.credit_amount, t.credit_ref, t.credit_received_at,
      t.created_at AS since,
      (SELECT s.id FROM supplier_invoices s WHERE t.purchase_order_id IS NOT NULL AND s.purchase_order_id = t.purchase_order_id AND coalesce(s.total, 0) > 0
         AND coalesce(s.doc_type, 'invoice') NOT IN ('credit', 'return') ORDER BY s.id LIMIT 1) AS sinv_id,
      coalesce((SELECT m.supplier_invoice_id FROM supplier_credit_memos m WHERE m.tank_order_id = t.id ORDER BY m.id DESC LIMIT 1),
        (SELECT s.id FROM supplier_invoices s WHERE t.purchase_order_id IS NOT NULL AND s.purchase_order_id = t.purchase_order_id AND coalesce(s.total, 0) < 0 ORDER BY s.id LIMIT 1)) AS credit_id
    FROM tank_orders t
    WHERE coalesce(t.credit_status, '') <> 'cancelled' AND (p_job IS NULL OR t.job_id = p_job)
      AND NOT EXISTS (SELECT 1 FROM invoices i WHERE i.id = t.invoice_id AND i.status = 'void')
    UNION ALL
    SELECT 'o' || s.id, 'old', NULL, lk.job_id, lk.invoice_id, s.supplier_id, s.purchase_order_id,
      (SELECT left(coalesce(nullif(l ->> 'description', ''), l ->> 'code', ''), 200) FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.lines) = 'array' THEN s.lines ELSE '[]'::jsonb END) l LIMIT 1),
      coalesce(nullif(s.subtotal, 0), round(s.total / 1.13, 2)), 'partner', NULL, NULL, NULL, NULL, NULL, coalesce(s.invoice_date::timestamptz, o.added_at),
      s.id,
      (SELECT c.id FROM supplier_invoices c WHERE c.supplier_id = s.supplier_id AND coalesce(c.total, 0) < 0 AND c.id <> s.id
         AND ((public._rt_num(c.original_order) <> '' AND public._rt_num(c.original_order) = public._rt_num(s.supplier_invoice_number))
           OR (s.purchase_order_id IS NOT NULL AND c.purchase_order_id = s.purchase_order_id)
           OR (public._rt_num(s.po_text) <> '' AND public._rt_num(c.po_text) = public._rt_num(s.po_text) AND abs(c.total + s.total) < 1))
         ORDER BY c.id LIMIT 1)
    FROM rental_tank_old o JOIN supplier_invoices s ON s.id = o.supplier_invoice_id
      LEFT JOIN LATERAL (SELECT i.id AS invoice_id, i.job_id FROM supplier_invoice_customer_links l JOIN invoices i ON i.id = l.invoice_id LEFT JOIN jobs j ON j.id = i.job_id
        WHERE l.supplier_invoice_id = s.id ORDER BY (i.bill_to_partner_id IS NOT NULL OR j.partner_id IS NOT NULL) DESC, l.linked_at LIMIT 1) lk ON true
    WHERE (p_job IS NULL OR lk.job_id = p_job)
      AND NOT EXISTS (SELECT 1 FROM tank_orders t WHERE s.purchase_order_id IS NOT NULL AND t.purchase_order_id = s.purchase_order_id AND coalesce(t.credit_status, '') <> 'cancelled')
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('key', b.key, 'src', b.src, 'tank_order_id', b.tank_order_id, 'payer', b.payer, 'description', b.description,
      'cost', CASE WHEN v_cost THEN b.cost END, 'supplier_id', b.supplier_id, 'supplier', btrim(sp.name), 'since', b.since,
      'cust_id', coalesce(i.customer_id, j.customer_id), 'customer', c.display_name, 'job_id', b.job_id, 'job_number', j.job_number,
      'inv', CASE WHEN i.id IS NOT NULL THEN jsonb_build_object('id', i.id, 'number', i.invoice_number, 'status', i.status, 'date', i.invoice_date,
        'sub', i.subtotal, 'total', i.total, 'balance', i.balance_due, 'partner', btrim(pt.name)) END,
      'rate', vp.rate, 'allowance', vp.allowance,
      'po', CASE WHEN po.id IS NOT NULL THEN jsonb_build_object('id', po.id, 'number', po.po_number, 'status', po.status, 'amount', CASE WHEN v_cost THEN po.amount END) END,
      'sinv', CASE WHEN si.id IS NOT NULL THEN jsonb_build_object('id', si.id, 'number', si.supplier_invoice_number, 'date', si.invoice_date, 'due', si.due_date,
        'total', CASE WHEN v_cost THEN si.total END, 'sup', si.supplier_id,
        'pages', (SELECT count(*) FROM supplier_doc_pages p WHERE p.supplier_invoice_id = si.id)) END,
      'co', CASE WHEN b.credit_number IS NOT NULL THEN jsonb_build_object('number', b.credit_number, 'status', b.credit_status,
        'amount', CASE WHEN v_cost THEN b.credit_amount END, 'ref', b.credit_ref, 'at', b.credit_received_at) END,
      'credit', CASE WHEN cr.id IS NOT NULL THEN jsonb_build_object('id', cr.id, 'number', cr.supplier_invoice_number, 'date', cr.invoice_date,
        'total', CASE WHEN v_cost THEN cr.total END, 'sup', cr.supplier_id,
        'memo', (SELECT m.memo_number FROM supplier_credit_memos m WHERE m.supplier_invoice_id = cr.id ORDER BY m.id DESC LIMIT 1)) END)
      ORDER BY b.since DESC NULLS LAST, b.key), '[]'::jsonb) INTO v
  FROM base b
    LEFT JOIN jobs j ON j.id = b.job_id
    LEFT JOIN invoices i ON i.id = b.invoice_id
    LEFT JOIN customers c ON c.id = coalesce(i.customer_id, j.customer_id)
    LEFT JOIN partners pt ON pt.id = coalesce(i.bill_to_partner_id, j.partner_id)
    LEFT JOIN suppliers sp ON sp.id = b.supplier_id
    LEFT JOIN purchase_orders po ON po.id = b.po_id
    LEFT JOIN supplier_invoices si ON si.id = b.sinv_id
    LEFT JOIN supplier_invoices cr ON cr.id = b.credit_id
    LEFT JOIN LATERAL (SELECT p.rate, p.allowance FROM vista_rental_picks p WHERE p.kind = 'job' AND p.ref_id = b.job_id ORDER BY p.set_at DESC LIMIT 1) vp ON true;
  RETURN jsonb_build_object('ok', true, 'costs', v_cost, 'rows', v);
END $function$;

-- bring an older tank in by its supplier invoice number (the supplier is optional: it is asked for only when two suppliers have that number)
CREATE OR REPLACE FUNCTION public.rental_tank_old_add(p_number text, p_supplier bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_n int; s supplier_invoices;
BEGIN
  IF NOT public._tank_office() THEN RAISE EXCEPTION 'Only the office can add a tank to this list'; END IF;
  IF public._rt_num(p_number) = '' THEN RAISE EXCEPTION 'Type the supplier''s invoice number'; END IF;
  SELECT count(*) INTO v_n FROM supplier_invoices x WHERE public._rt_num(x.supplier_invoice_number) = public._rt_num(p_number) AND coalesce(x.total, 0) > 0
    AND (p_supplier IS NULL OR x.supplier_id = p_supplier);
  IF v_n = 0 THEN RAISE EXCEPTION 'I can not find a supplier invoice with the number %. Load it on Supplier invoices first.', btrim(p_number); END IF;
  IF v_n > 1 THEN RAISE EXCEPTION 'More than one supplier has an invoice with the number %. Open the right one on Supplier invoices and tell Claude which.', btrim(p_number); END IF;
  SELECT * INTO s FROM supplier_invoices x WHERE public._rt_num(x.supplier_invoice_number) = public._rt_num(p_number) AND coalesce(x.total, 0) > 0
    AND (p_supplier IS NULL OR x.supplier_id = p_supplier);
  IF EXISTS (SELECT 1 FROM rental_tank_old o WHERE o.supplier_invoice_id = s.id) THEN RAISE EXCEPTION 'Invoice % is already on the Rental tanks list', s.supplier_invoice_number; END IF;
  INSERT INTO rental_tank_old (supplier_invoice_id, added_by) VALUES (s.id, public.current_app_user_id());
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
    VALUES ('rental_tank_old', s.id, 'insert', public.current_app_user_id(), jsonb_build_object('supplier_invoice', s.supplier_invoice_number));
  RETURN jsonb_build_object('id', s.id, 'number', s.supplier_invoice_number);
END $function$;

-- take an older tank off the list (only the line on this list: no paper is changed)
CREATE OR REPLACE FUNCTION public.rental_tank_old_remove(p_id bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._tank_office() THEN RAISE EXCEPTION 'Only the office can take a tank off this list'; END IF;
  DELETE FROM rental_tank_old WHERE supplier_invoice_id = p_id;
  IF NOT FOUND THEN RETURN false; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
    VALUES ('rental_tank_old', p_id, 'delete', public.current_app_user_id(), '{}'::jsonb);
  RETURN true;
END $function$;

REVOKE EXECUTE ON FUNCTION public.rental_tanks(bigint), public.rental_tank_old_add(text, bigint), public.rental_tank_old_remove(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rental_tanks(bigint), public.rental_tank_old_add(text, bigint), public.rental_tank_old_remove(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

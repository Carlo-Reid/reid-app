-- A Credit Order for a part sent back to a supplier (Carlo, Nov 26, 2026: "If we get a Credit Order from them then we need to match it with our system
-- Credit Order and connect it to a customer or apply it to stock"). The tank Credit Order (CO-<n>, 259) is only for a Vista rental tank; this one is for any
-- part of any supplier: a warranty part, a wrong part, a part not needed. CO-R<n>.
--   made from an open supplier invoice (the line sent back) or by hand; for a customer's invoice, or for our stock (then the part can be taken out of stock)
--   waits until the supplier's credit comes in; then it answers itself: same supplier, and the credit names the invoice it takes back (original order),
--   or the credit has a line with the same part number for about the same amount (within 10%), and only one waiting order fits
--   when it is answered: the credit gets its Credit Memo, and is tied to the Credit Order's customer invoice
CREATE TABLE IF NOT EXISTS public.part_credit_orders (
  id bigserial PRIMARY KEY, supplier_id bigint NOT NULL, from_sinv_id bigint, item_code text, description text, quantity numeric, amount numeric,
  invoice_id bigint, for_stock boolean NOT NULL DEFAULT false, stock_txn_id bigint, reason text, note text,
  status text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'received', 'cancelled')),
  credit_sinv_id bigint, received_at timestamptz, received_how text, received_by bigint,
  created_by bigint, created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.part_credit_orders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.part_credit_orders FROM PUBLIC, anon, authenticated;
CREATE INDEX IF NOT EXISTS part_credit_orders_wait ON public.part_credit_orders (supplier_id) WHERE status = 'waiting';
CREATE INDEX IF NOT EXISTS part_credit_orders_from ON public.part_credit_orders (from_sinv_id);
CREATE INDEX IF NOT EXISTS part_credit_orders_credit ON public.part_credit_orders (credit_sinv_id);

CREATE OR REPLACE FUNCTION public._pco_key(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $f$ SELECT upper(regexp_replace(coalesce(t, ''), '[^A-Za-z0-9]', '', 'g')) $f$;

CREATE OR REPLACE FUNCTION public._pco_json(o part_credit_orders) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT jsonb_build_object('id', o.id, 'number', 'CO-R' || o.id, 'supplier_id', o.supplier_id, 'supplier', (SELECT btrim(name) FROM suppliers WHERE id = o.supplier_id),
    'from_sinv', o.from_sinv_id, 'from_number', (SELECT supplier_invoice_number FROM supplier_invoices WHERE id = o.from_sinv_id),
    'code', o.item_code, 'description', o.description, 'qty', o.quantity, 'amount', CASE WHEN public._can_see_costs() THEN o.amount END,
    'invoice', o.invoice_id, 'invoice_number', (SELECT invoice_number FROM invoices WHERE id = o.invoice_id),
    'customer_id', (SELECT customer_id FROM invoices WHERE id = o.invoice_id),
    'customer', (SELECT c.display_name FROM invoices i JOIN customers c ON c.id = i.customer_id WHERE i.id = o.invoice_id),
    'stock', o.for_stock, 'out_of_stock', o.stock_txn_id IS NOT NULL, 'reason', o.reason, 'note', o.note, 'status', o.status,
    'credit', o.credit_sinv_id, 'credit_number', (SELECT supplier_invoice_number FROM supplier_invoices WHERE id = o.credit_sinv_id),
    'credit_amount', CASE WHEN public._can_see_costs() THEN (SELECT abs(coalesce(nullif(subtotal, 0), total)) FROM supplier_invoices WHERE id = o.credit_sinv_id) END,
    'received_at', o.received_at, 'received_how', o.received_how, 'at', o.created_at,
    'by', (SELECT public._emp_name(u.employee_id) FROM app_users u WHERE u.id = o.created_by)) $f$;

-- make one (office people, owners, people who make P.O.s)
CREATE OR REPLACE FUNCTION public.part_credit_order_make(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE o part_credit_orders; v_sup bigint; v_from bigint := nullif(p ->> 'from_sinv', '')::bigint; v_inv bigint := nullif(p ->> 'invoice', '')::bigint;
  v_stock boolean := coalesce((p ->> 'stock')::boolean, false); v_place bigint := nullif(p ->> 'place', '')::bigint; v_qty numeric := nullif(p ->> 'qty', '')::numeric;
  v_code text := nullif(btrim(coalesce(p ->> 'code', '')), ''); v_item bigint; v_res jsonb; v_me bigint := public.current_app_user_id(); v_job bigint;
BEGIN
  IF NOT coalesce(public._tank_office(), false) THEN RAISE EXCEPTION 'Only the office can make a Credit Order'; END IF;
  v_sup := coalesce(nullif(p ->> 'supplier', '')::bigint, (SELECT supplier_id FROM supplier_invoices WHERE id = v_from));
  IF v_sup IS NULL OR NOT EXISTS (SELECT 1 FROM suppliers WHERE id = v_sup) THEN RAISE EXCEPTION 'Pick the supplier'; END IF;
  IF v_code IS NULL AND nullif(btrim(coalesce(p ->> 'description', '')), '') IS NULL THEN RAISE EXCEPTION 'Say which part goes back'; END IF;
  IF v_qty IS NULL OR v_qty <= 0 OR v_qty > 10000 THEN RAISE EXCEPTION 'Type how many go back'; END IF;
  IF NOT v_stock AND v_inv IS NULL THEN RAISE EXCEPTION 'Pick the customer invoice, or Our stock'; END IF;
  IF v_inv IS NOT NULL AND NOT EXISTS (SELECT 1 FROM invoices WHERE id = v_inv) THEN RAISE EXCEPTION 'That customer invoice is not in the system'; END IF;
  INSERT INTO part_credit_orders (supplier_id, from_sinv_id, item_code, description, quantity, amount, invoice_id, for_stock, reason, note, created_by)
  VALUES (v_sup, v_from, v_code, nullif(btrim(coalesce(p ->> 'description', '')), ''), v_qty, nullif(p ->> 'amount', '')::numeric,
          CASE WHEN v_stock THEN NULL ELSE v_inv END, v_stock, nullif(btrim(coalesce(p ->> 'reason', '')), ''), nullif(btrim(coalesce(p ->> 'note', '')), ''), v_me)
  RETURNING * INTO o;
  -- from our stock: take it out now, when the part is in our price list and a place is picked
  IF v_stock AND v_place IS NOT NULL AND v_code IS NOT NULL THEN
    SELECT si.item_id INTO v_item FROM supplier_items si WHERE si.supplier_id = v_sup AND public._pco_key(si.supplier_sku) = public._pco_key(v_code) ORDER BY si.is_preferred DESC NULLS LAST, si.id LIMIT 1;
    IF v_item IS NULL THEN SELECT id INTO v_item FROM pricebook_items WHERE public._pco_key(sku) = public._pco_key(v_code) ORDER BY active DESC, id LIMIT 1; END IF;
    IF v_item IS NULL THEN RAISE EXCEPTION 'Part % is not in our price list, so it can not be taken out of stock. Leave the place empty to make the Credit Order only.', v_code; END IF;
    v_res := public.stock_move(jsonb_build_object('item', v_item, 'kind', 'out', 'place', v_place, 'qty', v_qty, 'note', 'Sent back to the supplier: Credit Order CO-R' || o.id));
    UPDATE part_credit_orders SET stock_txn_id = (v_res ->> 'txn')::bigint WHERE id = o.id RETURNING * INTO o;
  END IF;
  SELECT job_id INTO v_job FROM invoices WHERE id = o.invoice_id;
  INSERT INTO notes (entity_type, entity_id, body, source)
  SELECT 'job', v_job, 'Credit Order CO-R' || o.id || ': ' || o.quantity || ' x ' || coalesce(o.item_code || ' ', '') || coalesce(o.description, '') || ' sent back to '
         || (SELECT btrim(name) FROM suppliers WHERE id = v_sup) || '. Waiting for their credit.', 'po' WHERE v_job IS NOT NULL;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('part_credit_orders', o.id, 'insert', v_me, to_jsonb(o));
  -- the credit may be in already
  PERFORM public._pco_auto(si.id) FROM supplier_invoices si WHERE si.supplier_id = v_sup AND (si.doc_type IN ('credit', 'return') OR si.total < 0)
    AND si.invoice_date >= (current_date - 120) AND NOT EXISTS (SELECT 1 FROM part_credit_orders x WHERE x.credit_sinv_id = si.id);
  SELECT * INTO o FROM part_credit_orders WHERE id = o.id;
  RETURN public._pco_json(o);
END $f$;

-- a supplier's credit came in: answer the one waiting Credit Order it fits
CREATE OR REPLACE FUNCTION public._pco_auto(p_invoice bigint) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE i supplier_invoices; v_id bigint; v_n int; v_orig text;
BEGIN
  SELECT * INTO i FROM supplier_invoices WHERE id = p_invoice;
  IF i.id IS NULL OR NOT (i.doc_type IN ('credit', 'return') OR coalesce(i.total, 0) < 0) THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM part_credit_orders WHERE credit_sinv_id = i.id) THEN RETURN NULL; END IF;
  v_orig := nullif(public._pco_key(i.original_order), '');
  WITH w AS (SELECT o.* FROM part_credit_orders o WHERE o.status = 'waiting' AND o.supplier_id = i.supplier_id AND o.created_at <= coalesce(i.invoice_date::timestamptz, now()) + interval '30 days'),
  byorig AS (SELECT w.id FROM w JOIN supplier_invoices f ON f.id = w.from_sinv_id WHERE v_orig IS NOT NULL AND public._pco_key(f.supplier_invoice_number) = v_orig),
  bycode AS (SELECT DISTINCT w.id FROM w CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(i.lines) = 'array' THEN i.lines ELSE '[]'::jsonb END) e
             WHERE w.item_code IS NOT NULL AND public._pco_key(e ->> 'code') = public._pco_key(w.item_code)
               AND (w.amount IS NULL OR coalesce(abs(nullif(e ->> 'net_amount', '')::numeric), abs(coalesce(i.subtotal, i.total))) BETWEEN w.amount * 0.9 AND w.amount * 1.1)),
  cand AS (SELECT id FROM byorig UNION SELECT id FROM bycode WHERE NOT EXISTS (SELECT 1 FROM byorig))
  SELECT min(id), count(*) INTO v_id, v_n FROM cand;
  IF v_n <> 1 THEN RETURN NULL; END IF;
  PERFORM public._pco_answer(v_id, i.id, 'auto');
  RETURN v_id;
END $f$;

CREATE OR REPLACE FUNCTION public._pco_answer(p_id bigint, p_credit bigint, p_how text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE o part_credit_orders; i supplier_invoices; v_job bigint;
BEGIN
  SELECT * INTO o FROM part_credit_orders WHERE id = p_id; SELECT * INTO i FROM supplier_invoices WHERE id = p_credit;
  UPDATE part_credit_orders SET status = 'received', credit_sinv_id = i.id, received_at = now(), received_how = p_how,
    received_by = CASE WHEN p_how = 'hand' THEN public.current_app_user_id() END WHERE id = o.id;
  PERFORM public._credit_memo_make(i.id, CASE WHEN p_how = 'auto' THEN 'auto' ELSE 'hand' END, NULL);
  IF o.invoice_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM supplier_invoice_customer_unlinks u WHERE u.supplier_invoice_id = i.id AND u.invoice_id = o.invoice_id) THEN
    INSERT INTO supplier_invoice_customer_links (supplier_invoice_id, invoice_id, linked_by, auto) VALUES (i.id, o.invoice_id, NULL, true) ON CONFLICT DO NOTHING;
    INSERT INTO sinv_cust_guess (supplier_invoice_id, invoice_id, how) VALUES (i.id, o.invoice_id, 'credit order') ON CONFLICT DO NOTHING;
  END IF;
  SELECT job_id INTO v_job FROM invoices WHERE id = o.invoice_id;
  INSERT INTO notes (entity_type, entity_id, body, source)
  SELECT 'job', v_job, 'Credit Order CO-R' || o.id || ': the credit came back (' || coalesce(i.supplier_invoice_number, 'credit') || ')'
         || CASE WHEN p_how = 'auto' THEN '. The app matched it by itself.' ELSE '.' END, 'po' WHERE v_job IS NOT NULL;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('part_credit_orders', o.id, 'update', public.current_app_user_id(), jsonb_build_object('step', 'received', 'how', p_how, 'credit', i.supplier_invoice_number));
END $f$;

-- by hand: the credit came back (pick the credit paper), back to waiting, cancel
CREATE OR REPLACE FUNCTION public.part_credit_order_set(p_id bigint, p_action text, p_credit bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE o part_credit_orders;
BEGIN
  IF NOT coalesce(public._tank_office(), false) THEN RAISE EXCEPTION 'Only the office can change a Credit Order'; END IF;
  SELECT * INTO o FROM part_credit_orders WHERE id = p_id; IF o.id IS NULL THEN RAISE EXCEPTION 'Credit Order not found'; END IF;
  IF p_action = 'received' THEN
    IF NOT EXISTS (SELECT 1 FROM supplier_invoices WHERE id = p_credit AND supplier_id = o.supplier_id AND (doc_type IN ('credit', 'return') OR total < 0)) THEN
      RAISE EXCEPTION 'Pick a credit from the same supplier'; END IF;
    IF EXISTS (SELECT 1 FROM part_credit_orders WHERE credit_sinv_id = p_credit AND id <> o.id) THEN RAISE EXCEPTION 'That credit already answered another Credit Order'; END IF;
    PERFORM public._pco_answer(o.id, p_credit, 'hand');
  ELSIF p_action = 'waiting' THEN
    UPDATE part_credit_orders SET status = 'waiting', credit_sinv_id = NULL, received_at = NULL, received_how = NULL, received_by = NULL WHERE id = o.id;
  ELSIF p_action = 'cancel' THEN
    UPDATE part_credit_orders SET status = 'cancelled' WHERE id = o.id;
  ELSE RAISE EXCEPTION 'Unknown step'; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('part_credit_orders', o.id, 'update', public.current_app_user_id(), to_jsonb(o), jsonb_build_object('step', p_action, 'credit', p_credit));
  SELECT * INTO o FROM part_credit_orders WHERE id = p_id;
  RETURN public._pco_json(o);
END $f$;

-- the Credit Orders of one supplier paper: made from it (an invoice), or answered by it (a credit)
CREATE OR REPLACE FUNCTION public.part_credit_orders_for(p_sinv bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT coalesce(public._tank_office(), false) THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(public._pco_json(o) ORDER BY o.id) FROM part_credit_orders o WHERE o.from_sinv_id = p_sinv OR o.credit_sinv_id = p_sinv), '[]'::jsonb) END $f$;

-- every Credit Order, waiting first (the Credit Orders page and the Tasks page)
CREATE OR REPLACE FUNCTION public.part_credit_orders_list(p_status text DEFAULT NULL, p_supplier bigint DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT coalesce(public._tank_office(), false) THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(public._pco_json(o) ORDER BY (o.status = 'waiting') DESC, o.created_at DESC) FROM
      (SELECT * FROM part_credit_orders WHERE (p_status IS NULL OR status = p_status) AND (p_supplier IS NULL OR supplier_id = p_supplier) ORDER BY created_at DESC LIMIT 500) o), '[]'::jsonb) END $f$;

-- the credits of that supplier that could answer a Credit Order by hand (not used by another one), newest first
CREATE OR REPLACE FUNCTION public.part_credit_order_credits(p_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT coalesce(public._tank_office(), false) THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'number', s.supplier_invoice_number, 'date', s.invoice_date,
        'amount', CASE WHEN public._can_see_costs() THEN s.total END, 'what', left(coalesce(s.lines -> 0 ->> 'code', '') || ' ' || coalesce(s.lines -> 0 ->> 'description', ''), 80),
        'fits', public._pco_key(s.original_order) <> '' AND public._pco_key(s.original_order) = public._pco_key(f.supplier_invoice_number)
                OR EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.lines) = 'array' THEN s.lines ELSE '[]'::jsonb END) e WHERE public._pco_key(e ->> 'code') = public._pco_key(o.item_code)))
      ORDER BY s.invoice_date DESC, s.id DESC)
     FROM part_credit_orders o LEFT JOIN supplier_invoices f ON f.id = o.from_sinv_id
     JOIN LATERAL (SELECT * FROM supplier_invoices s WHERE s.supplier_id = o.supplier_id AND (s.doc_type IN ('credit', 'return') OR s.total < 0)
                     AND s.invoice_date >= (o.created_at::date - 30) AND NOT EXISTS (SELECT 1 FROM part_credit_orders x WHERE x.credit_sinv_id = s.id)
                   ORDER BY s.invoice_date DESC LIMIT 60) s ON true
     WHERE o.id = p_id), '[]'::jsonb) END $f$;

CREATE OR REPLACE FUNCTION public._trg_pco_auto() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NEW.doc_type IN ('credit', 'return') OR coalesce(NEW.total, 0) < 0 THEN
    BEGIN PERFORM public._pco_auto(NEW.id); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'credit order: %', SQLERRM; END;   -- never stops a supplier paper from saving
  END IF;
  RETURN NULL;
END $f$;
DROP TRIGGER IF EXISTS trg_pco_auto ON public.supplier_invoices;
CREATE TRIGGER trg_pco_auto AFTER INSERT OR UPDATE OF doc_type, original_order, lines, total, supplier_id ON public.supplier_invoices
  FOR EACH ROW EXECUTE FUNCTION public._trg_pco_auto();

REVOKE EXECUTE ON FUNCTION public._pco_auto(bigint), public._pco_answer(bigint, bigint, text), public._pco_json(part_credit_orders) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.part_credit_order_make(jsonb), public.part_credit_order_set(bigint, text, bigint), public.part_credit_orders_for(bigint),
  public.part_credit_orders_list(text, bigint), public.part_credit_order_credits(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

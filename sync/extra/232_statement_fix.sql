-- Our statement: click a line to fix it. Supplier invoices: date and total by hand; supplier payments: amount, date and note by hand. Safe to run more than once.
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
  IF p ? 'invoice_date' THEN
    IF nullif(p ->> 'invoice_date', '') IS NULL THEN RAISE EXCEPTION 'Pick a date'; END IF;
    UPDATE supplier_invoices SET invoice_date = (p ->> 'invoice_date')::date, updated_at = now() WHERE id = p_id; END IF;
  IF p ? 'total' THEN
    IF nullif(p ->> 'total', '') IS NULL THEN RAISE EXCEPTION 'Put in the amount'; END IF;
    UPDATE supplier_invoices SET total = (p ->> 'total')::numeric, subtotal = round((p ->> 'total')::numeric / 1.13, 2), hst = (p ->> 'total')::numeric - round((p ->> 'total')::numeric / 1.13, 2),
           read_notes = concat_ws(' · ', nullif(read_notes, ''), 'Amount changed by hand to ' || to_char((p ->> 'total')::numeric, 'FM$999,999,990.00') || ' (was ' || coalesce(to_char(total, 'FM$999,999,990.00'), 'none') || ')'), updated_at = now()
     WHERE id = p_id; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('supplier_invoices', p_id, 'update', public.current_app_user_id(), p);
END $function$;

CREATE OR REPLACE FUNCTION public.supplier_payment_edit(p_id bigint, p_amount numeric, p_paid_on date, p_note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE o supplier_payments;
BEGIN
  IF NOT public._sup_pay_ok() THEN RAISE EXCEPTION 'You don''t have permission to pay suppliers'; END IF;
  SELECT * INTO o FROM supplier_payments WHERE id = p_id AND voided_at IS NULL; IF NOT FOUND THEN RAISE EXCEPTION 'That payment isn''t there any more'; END IF;
  IF p_amount IS NULL OR p_amount = 0 THEN RAISE EXCEPTION 'Put in the amount (or cancel the payment)'; END IF;
  UPDATE supplier_payments SET amount = p_amount, paid_on = coalesce(p_paid_on, paid_on),
         note = concat_ws(' · ', nullif(btrim(coalesce(p_note, note, '')), ''), CASE WHEN p_amount <> o.amount THEN 'Amount changed by hand from ' || to_char(o.amount, 'FM$999,999,990.00') END)
   WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_payments', p_id, 'update', public.current_app_user_id(), jsonb_build_object('amount', p_amount, 'was', o.amount, 'paid_on', p_paid_on, 'note', p_note));
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_payment_edit(bigint, numeric, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_payment_edit(bigint, numeric, date, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

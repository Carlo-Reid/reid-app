-- Our statement: a line on their statement that we have no invoice for (or only its packing slip, $0) can be filled in
-- from their statement. The invoice is marked as made by the app ("Made by the app from their statement…") so it's clear
-- our own copy was missing. Safe to run more than once.
CREATE OR REPLACE FUNCTION public.supplier_invoice_from_statement(p_supplier bigint, p_number text, p_date date, p_amount numeric, p_statement_date date)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_id bigint; v_had boolean; v_note text; v_sub numeric;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF coalesce(btrim(p_number), '') = '' OR p_amount IS NULL THEN RAISE EXCEPTION 'The invoice number and amount are needed'; END IF;
  v_sub := round(p_amount / 1.13, 2);
  v_note := 'Made by the app from their statement of ' || to_char(p_statement_date, 'Mon FMDD, YYYY') || ' (' || to_char(p_amount, 'FM$999,999,990.00')
            || '): our copy of this ' || CASE WHEN p_amount < 0 THEN 'credit' ELSE 'invoice' END || ' was missing. Before tax and HST worked out at 13%.';
  SELECT id INTO v_id FROM supplier_invoices WHERE supplier_id = p_supplier AND supplier_invoice_number = btrim(p_number);
  v_had := v_id IS NOT NULL;
  IF v_had THEN
    IF coalesce((SELECT total FROM supplier_invoices WHERE id = v_id), 0) <> 0 THEN RAISE EXCEPTION 'We already have invoice % with an amount: open it on Supplier invoices', btrim(p_number); END IF;
    UPDATE supplier_invoices SET total = p_amount, subtotal = v_sub, hst = p_amount - v_sub, invoice_date = coalesce(p_date, invoice_date),
           doc_type = CASE WHEN p_amount < 0 THEN 'credit' ELSE coalesce(doc_type, 'invoice') END,
           read_notes = v_note || coalesce(' · Before: ' || nullif(read_notes, ''), ''), updated_at = now()
     WHERE id = v_id;
  ELSE
    INSERT INTO supplier_invoices (supplier_id, supplier_invoice_number, invoice_date, total, doc_type, subtotal, hst, lines, read_notes)
    VALUES (p_supplier, btrim(p_number), p_date, p_amount, CASE WHEN p_amount < 0 THEN 'credit' ELSE 'invoice' END, v_sub, p_amount - v_sub, '[]'::jsonb, v_note)
    RETURNING id INTO v_id;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoices', v_id, CASE WHEN v_had THEN 'update' ELSE 'insert' END, public.current_app_user_id(),
          jsonb_build_object('from_statement', p_statement_date, 'number', p_number, 'amount', p_amount));
  RETURN jsonb_build_object('id', v_id, 'filled', v_had);
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_from_statement(bigint, text, date, numeric, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_from_statement(bigint, text, date, numeric, date) TO authenticated;
NOTIFY pgrst, 'reload schema';

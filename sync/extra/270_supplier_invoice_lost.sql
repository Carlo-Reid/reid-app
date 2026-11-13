-- A supplier invoice we lost (Carlo, Nov 12, 2026: "if we ever lose a supplier invoice have a way to create it as well, like we did with the credit, and have it
-- also have a watermark that says we made this because we lost the original"). Makes our record of it (number, date, amount with tax, P.O.) with a system copy.
-- The mark is in read_notes ("because the original was lost"), which is what the app's watermark reads.
CREATE OR REPLACE FUNCTION public.supplier_invoice_lost_make(p_supplier bigint, p_number text, p_date date, p_amount numeric, p_po text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id bigint; v_sub numeric; v_day text := to_char(now() AT TIME ZONE 'America/Toronto', 'Mon FMDD, YYYY');
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF coalesce(btrim(p_number), '') = '' OR p_amount IS NULL OR p_amount = 0 THEN RAISE EXCEPTION 'The invoice number and the amount are needed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier) THEN RAISE EXCEPTION 'Pick the supplier first'; END IF;
  IF EXISTS (SELECT 1 FROM supplier_invoices WHERE supplier_id = p_supplier AND supplier_invoice_number = btrim(p_number)) THEN
    RAISE EXCEPTION 'We already have % from this supplier. Open it and press Create one from the system there.', btrim(p_number); END IF;
  v_sub := round(p_amount / 1.13, 2);
  INSERT INTO supplier_invoices (supplier_id, supplier_invoice_number, invoice_date, total, doc_type, subtotal, hst, lines, po_text, read_notes)
  VALUES (p_supplier, btrim(p_number), coalesce(p_date, (now() AT TIME ZONE 'America/Toronto')::date), p_amount, CASE WHEN p_amount < 0 THEN 'credit' ELSE 'invoice' END, v_sub, p_amount - v_sub, '[]'::jsonb, nullif(btrim(coalesce(p_po, '')), ''),
          'Made by the app on ' || v_day || ' because the original was lost. Before tax and HST worked out at 13%. System generated copy made in the app on ' || v_day || ': ask the supplier for a copy of the original.')
  RETURNING id INTO v_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoices', v_id, 'insert', public.current_app_user_id(), jsonb_build_object('lost_original', true, 'number', p_number, 'amount', p_amount));
  RETURN jsonb_build_object('id', v_id);
END $$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_lost_make(bigint, text, date, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_lost_make(bigint, text, date, numeric, text) TO authenticated;

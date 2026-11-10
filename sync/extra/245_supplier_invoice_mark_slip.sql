-- Supplier invoices: "Click here if it's a Packing Slip" (Carlo, Nov 10, 2026). Marks the document as a packing slip so it shows under View Packing Slips
-- (that list is every document whose notes say "packing slip"). Undo takes the mark off again. Only the mark made here is ever removed.
CREATE OR REPLACE FUNCTION public.supplier_invoice_mark_slip(p_id bigint, p_on boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_notes text;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  SELECT coalesce(read_notes, '') INTO v_notes FROM supplier_invoices WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
  IF p_on THEN
    IF v_notes ILIKE '%Marked as a packing slip in the app%' THEN RETURN; END IF;   -- a paper the reader only guessed was a packing slip still gets the person's mark
    UPDATE supplier_invoices SET read_notes = btrim(v_notes || ' Marked as a packing slip in the app on ' || to_char(now() AT TIME ZONE 'America/Toronto', 'Mon FMDD, YYYY') || '.'), updated_at = now() WHERE id = p_id;
  ELSE
    UPDATE supplier_invoices SET read_notes = nullif(btrim(regexp_replace(v_notes, '\s*Marked as a packing slip in the app on [A-Za-z]{3} [0-9]{1,2}, [0-9]{4}\.', '', 'g')), ''), updated_at = now() WHERE id = p_id;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoices', p_id, 'update', public.current_app_user_id(), jsonb_build_object('packing_slip', p_on));
END $$;
REVOKE ALL ON FUNCTION public.supplier_invoice_mark_slip(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_mark_slip(bigint, boolean) TO authenticated;

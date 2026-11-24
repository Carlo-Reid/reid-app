-- Supplier invoices: "Create one from the system" under the Packing Slip square (Carlo, Nov 24, 2026). When the P.O. is found but the
-- packing slip is not, the app can draw a packing slip from what we know, with a watermark that says we made it and it is not the
-- supplier's original. This marks the record, so the app shows it for everyone. The mark is in read_notes, as the system copy of an
-- invoice is (267). Its words never say "packing slip" on purpose: those two words in read_notes mean the paper IS a packing slip
-- (116, 245, 263, 271). Safe to run more than once.
CREATE OR REPLACE FUNCTION public.supplier_invoice_system_slip(p_id bigint, p_on boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_notes text;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  SELECT coalesce(read_notes, '') INTO v_notes FROM supplier_invoices WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
  IF p_on THEN
    IF v_notes ILIKE '%Shipping paper made by the system in the app%' THEN RETURN; END IF;
    UPDATE supplier_invoices SET read_notes = btrim(v_notes || ' Shipping paper made by the system in the app on ' || to_char(now() AT TIME ZONE 'America/Toronto', 'Mon FMDD, YYYY') || ': it is not the supplier''s original.'), updated_at = now() WHERE id = p_id;
  ELSE
    UPDATE supplier_invoices SET read_notes = nullif(btrim(regexp_replace(v_notes, '\s*Shipping paper made by the system in the app on [A-Za-z]{3} [0-9]{1,2}, [0-9]{4}: it is not the supplier''s original\.', '', 'g')), ''), updated_at = now() WHERE id = p_id;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoices', p_id, 'update', public.current_app_user_id(), jsonb_build_object('system_slip', p_on));
END $$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_system_slip(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_system_slip(bigint, boolean) TO authenticated;

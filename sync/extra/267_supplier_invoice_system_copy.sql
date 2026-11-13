-- A supplier invoice we have no copy of: "Create one from the system" (Carlo, Nov 12, 2026). It marks the record, so the app shows a
-- system-made copy that always says to ask the supplier for the original. The mark is in read_notes, as the packing slip mark is.
CREATE OR REPLACE FUNCTION public.supplier_invoice_system_copy(p_id bigint, p_on boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_notes text;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  SELECT coalesce(read_notes, '') INTO v_notes FROM supplier_invoices WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
  IF p_on THEN
    IF v_notes ILIKE '%System generated copy made in the app%' THEN RETURN; END IF;
    UPDATE supplier_invoices SET read_notes = btrim(v_notes || ' System generated copy made in the app on ' || to_char(now() AT TIME ZONE 'America/Toronto', 'Mon FMDD, YYYY') || ': ask the supplier for a copy of the original.'), updated_at = now() WHERE id = p_id;
  ELSE
    UPDATE supplier_invoices SET read_notes = nullif(btrim(regexp_replace(v_notes, '\s*System generated copy made in the app on [A-Za-z]{3} [0-9]{1,2}, [0-9]{4}: ask the supplier for a copy of the original\.', '', 'g')), ''), updated_at = now() WHERE id = p_id;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoices', p_id, 'update', public.current_app_user_id(), jsonb_build_object('system_copy', p_on));
END $$;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_system_copy(bigint, boolean) TO authenticated;

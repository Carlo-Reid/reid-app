-- Supplier invoices: "Create it from the P.O." on a paper with a missing page (Carlo, Nov 24, 2026, on C381229: "its missing the second page so use
-- the P.O. to create it like we can on the supplier page with the water mark an all same way"). This only marks the record; the app draws the page
-- each time from the P.O.'s lines that are not on the pages on file, with a watermark that says we made it. The mark is in read_notes, like the
-- system copy (267) and the system's shipping paper (331). Its words never say "packing slip". Safe to run more than once.
CREATE OR REPLACE FUNCTION public.supplier_invoice_system_page(p_id bigint, p_on boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_notes text;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  SELECT coalesce(read_notes, '') INTO v_notes FROM supplier_invoices WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
  IF p_on THEN
    IF v_notes ILIKE '%Missing page made by the system in the app%' THEN RETURN; END IF;
    UPDATE supplier_invoices SET read_notes = btrim(v_notes || ' Missing page made by the system in the app on ' || to_char(now() AT TIME ZONE 'America/Toronto', 'Mon FMDD, YYYY') || ' from our P.O.: it is not the supplier''s original.'), updated_at = now() WHERE id = p_id;
  ELSE
    UPDATE supplier_invoices SET read_notes = nullif(btrim(regexp_replace(v_notes, '\s*Missing page made by the system in the app on [A-Za-z]{3} [0-9]{1,2}, [0-9]{4} from our P\.O\.: it is not the supplier''s original\.', '', 'g')), ''), updated_at = now() WHERE id = p_id;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoices', p_id, 'update', public.current_app_user_id(), jsonb_build_object('system_page', p_on));
END $$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_system_page(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_system_page(bigint, boolean) TO authenticated;
NOTIFY pgrst, 'reload schema';

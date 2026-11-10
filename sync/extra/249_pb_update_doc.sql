-- Auto Update → Approvals: "See the paper" (Carlo, Nov 10: "attach the document as well with a button"). A waiting cost has no link to its
-- paper, only words like "invoice C448260" or "email Nov 9, 2026 doc123.pdf", so this finds it: an emailed file by its file name, else the
-- supplier invoice with that number and its scanned pages, else an emailed paper that mentions the number. Returns {pages:[ids]} (shown with
-- supplier_doc_page), {mail: id} (opened with supplier_mail_file) or {none: true}. Safe to run more than once.
CREATE OR REPLACE FUNCTION public.pb_update_doc(p_id bigint) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE u record; v_last text; v_mail bigint; v_inv bigint; v_pages jsonb;
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  SELECT * INTO u FROM pricebook_cost_updates WHERE id = p_id; IF NOT FOUND THEN RETURN NULL; END IF;
  v_last := substring(btrim(coalesce(u.doc_ref, '')) from '(\S+)$');
  IF coalesce(v_last, '') = '' THEN RETURN jsonb_build_object('none', true); END IF;
  IF u.doc_ref ~* '^email ' THEN
    SELECT id INTO v_mail FROM supplier_mail WHERE file_name = v_last ORDER BY received_at DESC LIMIT 1;
  ELSE
    SELECT si.id INTO v_inv FROM supplier_invoices si LEFT JOIN suppliers s ON s.id = si.supplier_id
     WHERE si.supplier_invoice_number = v_last AND EXISTS (SELECT 1 FROM supplier_doc_pages pg WHERE pg.supplier_invoice_id = si.id)
     ORDER BY (s.name ILIKE '%' || coalesce(u.supplier, '') || '%' OR coalesce(u.supplier, '') ILIKE '%' || s.name || '%') DESC, si.id DESC LIMIT 1;
    IF v_inv IS NOT NULL THEN
      SELECT jsonb_agg(pg.id ORDER BY pg.page_no, pg.id) INTO v_pages FROM supplier_doc_pages pg WHERE pg.supplier_invoice_id = v_inv;
      RETURN jsonb_build_object('pages', v_pages, 'invoice', v_inv, 'number', v_last);
    END IF;
    IF length(v_last) >= 5 THEN
      SELECT id INTO v_mail FROM supplier_mail WHERE data IS NOT NULL AND (ocr_text ILIKE '%' || v_last || '%' OR subject ILIKE '%' || v_last || '%' OR file_name ILIKE '%' || v_last || '%')
       ORDER BY (supplier ILIKE '%' || coalesce(u.supplier, '') || '%') DESC NULLS LAST, received_at DESC LIMIT 1;
    END IF;
  END IF;
  IF v_mail IS NOT NULL THEN RETURN jsonb_build_object('mail', v_mail); END IF;
  RETURN jsonb_build_object('none', true);
END $f$;
REVOKE EXECUTE ON FUNCTION public.pb_update_doc(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_update_doc(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

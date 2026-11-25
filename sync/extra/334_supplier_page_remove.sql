-- Supplier invoices: take a page off an invoice when it was put there by mistake, and put it back
-- (Carlo, Nov 25, 2026, on C392857: its packing slip showed a page of Boone's statement too,
--  "i need a way to delete the uploaded document if its a mistake").
-- The page is kept whole in the history (audit_log), so "Put it back" brings it back as it was.
-- The last page of an invoice is never taken off. The kept page count (supplier_invoice_pages_check)
-- goes by the pages on file, so it is worked out again by itself.

CREATE OR REPLACE FUNCTION public.supplier_invoice_page_remove(p_page bigint, p_why text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE d supplier_doc_pages; v_left int;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  SELECT * INTO d FROM supplier_doc_pages WHERE id = p_page;
  IF d.id IS NULL OR d.supplier_invoice_id IS NULL THEN RAISE EXCEPTION 'That page is not on a supplier invoice any more'; END IF;
  SELECT count(*) INTO v_left FROM supplier_doc_pages WHERE supplier_invoice_id = d.supplier_invoice_id;
  IF v_left <= 1 THEN RAISE EXCEPTION 'This is the only page of this invoice, so it can not be taken off'; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('supplier_doc_pages', d.id, 'delete', public.current_app_user_id(), to_jsonb(d),
          jsonb_build_object('why', coalesce(nullif(trim(p_why), ''), 'Taken off by hand: it does not belong on this invoice.'),
                             'supplier_invoice_id', d.supplier_invoice_id));
  DELETE FROM supplier_doc_pages WHERE id = d.id;
  -- the pages left keep their order, numbered again from 1
  UPDATE supplier_doc_pages t SET ord = s.o
    FROM (SELECT id, row_number() OVER (ORDER BY coalesce(ord, page_no), page_no, id) AS o
            FROM supplier_doc_pages WHERE supplier_invoice_id = d.supplier_invoice_id) s
   WHERE t.id = s.id AND t.ord IS NOT NULL AND t.ord IS DISTINCT FROM s.o;
  RETURN jsonb_build_object('removed', d.id, 'invoice', d.supplier_invoice_id, 'pages', v_left - 1);
END $f$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_page_remove(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_page_remove(bigint, text) TO authenticated;

-- put a page that was taken off back on its invoice, exactly as it was (from the history)
CREATE OR REPLACE FUNCTION public.supplier_invoice_page_restore(p_page bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE a audit_log; d supplier_doc_pages;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF EXISTS (SELECT 1 FROM supplier_doc_pages WHERE id = p_page) THEN RAISE EXCEPTION 'That page is already on file'; END IF;
  SELECT * INTO a FROM audit_log WHERE table_name = 'supplier_doc_pages' AND row_id = p_page AND action = 'delete'
     AND old_values ? 'image' ORDER BY id DESC LIMIT 1;
  IF a.id IS NULL THEN RAISE EXCEPTION 'I can not find that page in the history'; END IF;
  d := jsonb_populate_record(NULL::supplier_doc_pages, a.old_values);
  d.id := p_page;
  IF d.supplier_invoice_id IS NULL OR NOT EXISTS (SELECT 1 FROM supplier_invoices WHERE id = d.supplier_invoice_id) THEN
    RAISE EXCEPTION 'The invoice that page was on is gone'; END IF;
  INSERT INTO supplier_doc_pages OVERRIDING SYSTEM VALUE SELECT d.*;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_doc_pages', p_page, 'insert', public.current_app_user_id(),
          jsonb_build_object('why', 'Put back after it was taken off.', 'supplier_invoice_id', d.supplier_invoice_id));
  RETURN jsonb_build_object('restored', p_page, 'invoice', d.supplier_invoice_id);
END $f$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_page_restore(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_page_restore(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

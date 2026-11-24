-- Supplier invoices: the pages of an invoice are kept in their printed order, and a page is never on file twice
-- (Carlo, Nov 24, 2026: "i want the pages in order and i want it to delete any duplicate automatically").
-- The browser reads each page (it has the page reader) and says, for each one, the page number printed on it, the number of
-- its first item line, and its words. This file keeps those, removes a second copy of a page, and sets the order.
-- page_no is left alone (statement pages share it, UNIQUE (statement_id, page_no)); the order is the new column ord.
ALTER TABLE public.supplier_doc_pages ADD COLUMN IF NOT EXISTS ord int;
ALTER TABLE public.supplier_doc_pages ADD COLUMN IF NOT EXISTS printed_no int;
ALTER TABLE public.supplier_doc_pages ADD COLUMN IF NOT EXISTS first_line int;
ALTER TABLE public.supplier_doc_pages ADD COLUMN IF NOT EXISTS words text;

-- what is on file for an invoice, for the browser: no pictures, only what was read before
CREATE OR REPLACE FUNCTION public.supplier_invoice_pages_info(p_invoice bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to load supplier invoices'; END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'no', d.printed_no, 'line', d.first_line, 'words', d.words) ORDER BY coalesce(d.ord, d.page_no), d.page_no, d.id), '[]')
            FROM supplier_doc_pages d WHERE d.supplier_invoice_id = p_invoice);
END $f$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_pages_info(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_pages_info(bigint) TO authenticated;

-- p: { pages: [{image, no, line, words}], have: [{id, no, line, words}], drop: [page ids that are a second copy], by: 'no' | 'line',
--      po_text, subtotal, hst, file … (the rest goes to supplier_invoice_attach as it is) }
CREATE OR REPLACE FUNCTION public.supplier_invoice_pages_add(p_invoice bigint, p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_me bigint := public.current_app_user_id(); v_max bigint; v_add int := 0; v_drop int := 0; v_left int; v_unread int; x jsonb; d supplier_doc_pages;
  v_by text := CASE WHEN p ->> 'by' = 'line' THEN 'line' ELSE 'no' END;
  v_int text := '^[0-9]{1,4}$';
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to load supplier invoices'; END IF;
  IF NOT EXISTS (SELECT 1 FROM supplier_invoices WHERE id = p_invoice) THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
  SELECT coalesce(max(id), 0) INTO v_max FROM supplier_doc_pages;
  -- 1. the new pages, saved the usual way, then what was read on each is kept with it
  IF jsonb_typeof(p -> 'pages') = 'array' AND jsonb_array_length(p -> 'pages') > 0 THEN
    PERFORM public.supplier_invoice_attach(p_invoice, (p - 'have' - 'drop' - 'by') || jsonb_build_object('pages',
      (SELECT jsonb_agg(e.v -> 'image' ORDER BY e.o) FROM jsonb_array_elements(p -> 'pages') WITH ORDINALITY e(v, o))));
    UPDATE supplier_doc_pages t SET
        printed_no = CASE WHEN e.v ->> 'no' ~ v_int THEN (e.v ->> 'no')::int END,
        first_line = CASE WHEN e.v ->> 'line' ~ v_int THEN (e.v ->> 'line')::int END,
        words = left(e.v ->> 'words', 8000)
      FROM (SELECT id, row_number() OVER (ORDER BY page_no, id) AS o FROM supplier_doc_pages WHERE supplier_invoice_id = p_invoice AND id > v_max) n
      JOIN jsonb_array_elements(p -> 'pages') WITH ORDINALITY e(v, o) ON e.o = n.o
     WHERE t.id = n.id;
    v_add := jsonb_array_length(p -> 'pages');
  END IF;
  -- 2. what the browser just read on the pages that were already on file
  IF jsonb_typeof(p -> 'have') = 'array' THEN
    FOR x IN SELECT * FROM jsonb_array_elements(p -> 'have') LOOP
      UPDATE supplier_doc_pages SET
          printed_no = CASE WHEN x ->> 'no' ~ v_int THEN (x ->> 'no')::int END,
          first_line = CASE WHEN x ->> 'line' ~ v_int THEN (x ->> 'line')::int END,
          words = coalesce(left(x ->> 'words', 8000), words)
       WHERE id = (x ->> 'id')::bigint AND supplier_invoice_id = p_invoice;
    END LOOP;
  END IF;
  -- 3. a second copy of a page comes off: the ones the browser found by their words, and any page whose picture is the very same.
  --    The copy that is removed is kept whole in the history, so it can be put back. The last page of an invoice is never removed.
  FOR d IN
    SELECT t.* FROM supplier_doc_pages t WHERE t.supplier_invoice_id = p_invoice AND (
        (jsonb_typeof(p -> 'drop') = 'array' AND t.id IN (SELECT (v #>> '{}')::bigint FROM jsonb_array_elements(p -> 'drop') v WHERE v #>> '{}' ~ '^[0-9]+$'))
        OR EXISTS (SELECT 1 FROM supplier_doc_pages o WHERE o.supplier_invoice_id = p_invoice AND o.id < t.id AND md5(o.image) = md5(t.image)))
     ORDER BY t.id DESC
  LOOP
    SELECT count(*) INTO v_left FROM supplier_doc_pages WHERE supplier_invoice_id = p_invoice;
    EXIT WHEN v_left <= 1;
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
    VALUES ('supplier_doc_pages', d.id, 'delete', v_me,
      jsonb_build_object('supplier_invoice_id', p_invoice, 'statement_id', d.statement_id, 'page_no', d.page_no, 'ord', d.ord, 'doc_number', d.doc_number, 'kind', d.kind,
                         'printed_no', d.printed_no, 'first_line', d.first_line, 'image', d.image),
      jsonb_build_object('why', 'A second copy of a page that is already on this invoice. Removed by itself.'));
    DELETE FROM supplier_doc_pages WHERE id = d.id AND supplier_invoice_id = p_invoice;
    v_drop := v_drop + 1;
  END LOOP;
  -- 4. the order: by the page number printed on the page (or by the first item line when that is what could be read);
  --    a page where neither could be read stays after the others, in the order it was loaded
  UPDATE supplier_doc_pages t SET ord = s.o
    FROM (SELECT id, row_number() OVER (ORDER BY
                   CASE WHEN v_by = 'line' THEN first_line ELSE printed_no END NULLS LAST,
                   CASE WHEN v_by = 'line' THEN printed_no ELSE first_line END NULLS LAST,
                   coalesce(ord, page_no), page_no, id) AS o
            FROM supplier_doc_pages WHERE supplier_invoice_id = p_invoice) s
   WHERE t.id = s.id AND t.ord IS DISTINCT FROM s.o;
  SELECT count(*), count(*) FILTER (WHERE printed_no IS NULL AND first_line IS NULL) INTO v_left, v_unread FROM supplier_doc_pages WHERE supplier_invoice_id = p_invoice;
  IF v_add = 0 AND v_drop > 0 THEN
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
    VALUES ('supplier_invoices', p_invoice, 'update', v_me, jsonb_build_object('pages_tidied', true, 'duplicates_removed', v_drop, 'pages', v_left));
  END IF;
  RETURN jsonb_build_object('added', v_add, 'dropped', v_drop, 'pages', v_left, 'unread', v_unread, 'by', v_by);
END $f$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_pages_add(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_pages_add(bigint, jsonb) TO authenticated;

-- 5. everything that lists an invoice's pages reads them in the new order (ord), and by page_no where no order was set.
--    Patched in place, each only once; the older files make these functions again on a full run and this file patches them again.
DO $do$
DECLARE r record; v text; w text;
BEGIN
  FOR r IN SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.proname IN ('supplier_invoice_get', 'job_documents', 'po_supplier_invoices', 'pb_update_doc') LOOP
    v := pg_get_functiondef(r.oid);
    w := replace(replace(v, 'ORDER BY d.page_no', 'ORDER BY coalesce(d.ord, d.page_no), d.page_no'),
                 'ORDER BY pg.page_no, pg.id', 'ORDER BY coalesce(pg.ord, pg.page_no), pg.page_no, pg.id');
    IF w <> v THEN EXECUTE w; END IF;
  END LOOP;
END $do$;
NOTIFY pgrst, 'reload schema';

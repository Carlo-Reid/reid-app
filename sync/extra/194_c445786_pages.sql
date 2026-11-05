-- One-time fix: Boone invoice C445786 had a 12-invoice packet (F4124493.PDF) saved as its copy, with the wrong date and no total.
-- Each page was read and checked by eye: C445786 keeps its own two pages (Nov 2, 2026, $1,301.01); the credit memo C448405 against it
-- (Nov 4, -$146.73) is added with its two pages; every other page goes to the invoice it belongs to as an extra copy. Nothing is deleted.
DO $$ DECLARE v_inv bigint := 7601; v_sup bigint; v_cr bigint; r record; nxt int; moved int := 0;
BEGIN
  SELECT supplier_id INTO v_sup FROM supplier_invoices WHERE id = v_inv AND supplier_invoice_number = 'C445786';
  IF v_sup IS NULL OR NOT EXISTS (SELECT 1 FROM supplier_doc_pages WHERE id = 6982 AND supplier_invoice_id = v_inv) THEN RAISE NOTICE 'C445786 fix: already done'; RETURN; END IF;
  -- C445786 itself
  UPDATE supplier_invoices SET invoice_date = '2026-11-02', total = 1301.01, subtotal = 1151.34, hst = 149.67, doc_type = 'invoice', updated_at = now() WHERE id = v_inv;
  -- the credit memo against it
  SELECT id INTO v_cr FROM supplier_invoices WHERE supplier_id = v_sup AND supplier_invoice_number = 'C448405';
  IF v_cr IS NULL THEN
    INSERT INTO supplier_invoices (supplier_id, supplier_invoice_number, invoice_date, total, doc_type, subtotal, hst, read_notes)
    VALUES (v_sup, 'C448405', '2026-11-04', -146.73, 'credit', -129.85, -16.88, 'Credit memo against invoice C445786. Its pages were in F4124493.PDF (saved with C445786 before).') RETURNING id INTO v_cr;
  END IF;
  -- each page to the invoice it belongs to
  FOR r IN SELECT * FROM (VALUES (6982, 'C444498'), (6984, 'C445838'), (6985, 'C446557'), (6986, 'C447297'), (6987, 'C447316'), (6988, 'C448030'),
                                 (6989, 'C447918'), (6990, 'C447918'), (6991, 'C448260'), (6992, 'C449517'), (6993, 'C448405'), (7212, 'C448405')) v(page_id, num) LOOP
    UPDATE supplier_doc_pages p SET supplier_invoice_id = t.id,
      page_no = coalesce((SELECT max(q.page_no) FROM supplier_doc_pages q WHERE q.supplier_invoice_id = t.id), 0) + 1
    FROM supplier_invoices t WHERE p.id = r.page_id AND p.supplier_invoice_id = v_inv AND t.supplier_id = v_sup AND t.supplier_invoice_number = r.num;
    IF FOUND THEN moved := moved + 1; END IF;
  END LOOP;
  -- what's left with C445786: its own two pages, numbered 1 and 2
  UPDATE supplier_doc_pages SET page_no = page_no + 1000 WHERE supplier_invoice_id = v_inv;
  UPDATE supplier_doc_pages SET page_no = CASE id WHEN 6983 THEN 1 WHEN 7213 THEN 2 ELSE page_no - 1000 + 2 END WHERE supplier_invoice_id = v_inv;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('supplier_invoices', v_inv, 'update', NULL,
    jsonb_build_object('fix', 'C445786: its own pages, date and total; the packet''s other pages moved to their invoices', 'moved', moved, 'credit_memo', v_cr));
  RAISE NOTICE 'C445786 fix: % pages moved, credit memo C448405 is %', moved, v_cr;
END $$;

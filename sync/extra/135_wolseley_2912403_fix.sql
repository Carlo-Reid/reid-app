-- Wolseley "invoice" 2912403 was the whole January 2026 statement file (14 pages) saved as one invoice by mistake.
-- 2912403 is really Wolseley's order number on the last page (an order inquiry for PO 96496914, received Jan 12, 2026).
-- Keep it as that one packing slip: take the 14 pages off (the right page goes back on from the app) and fix its details.
DO $$
DECLARE v bigint;
BEGIN
  SELECT id INTO v FROM supplier_invoices WHERE supplier_id = 11 AND supplier_invoice_number = '2912403' AND coalesce(read_notes, '') NOT LIKE '%order inquiry%';
  IF v IS NULL THEN RETURN; END IF;
  DELETE FROM supplier_doc_pages WHERE supplier_invoice_id = v;
  UPDATE supplier_invoices SET invoice_date = DATE '2026-01-06', total = 0, subtotal = NULL, hst = NULL, po_text = '96496914', lines = '[]',
    read_notes = 'Packing slip: Wolseley order inquiry for order 2912403 (PO 96496914, the PO is corrected by hand from 9646914), received Jan 12, 2026. No invoice for it on the January statement yet.',
    updated_at = now()
  WHERE id = v;
  INSERT INTO audit_log (table_name, row_id, action, new_values)
  VALUES ('supplier_invoices', v, 'update', jsonb_build_object('fixed', 'The January statement file was saved as invoice 2912403; kept only its packing slip page'));
END $$;

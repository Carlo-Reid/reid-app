-- Take the Wolseley statement copy ("9. Wolseley Sept 2026.pdf", 42 pages) back off Trent Metal invoice 659612 (#2765), where it landed by mistake
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM supplier_invoices WHERE id = 2765 AND read_notes LIKE '%9. Wolseley Sept 2026%') THEN
    DELETE FROM supplier_doc_pages WHERE supplier_invoice_id = 2765;
    UPDATE supplier_invoices SET
      po_text = CASE WHEN po_text = '1LOK' THEN NULL ELSE po_text END,
      subtotal = CASE WHEN subtotal = -1729.7 THEN NULL ELSE subtotal END,
      hst = CASE WHEN hst = -224.87 THEN NULL ELSE hst END,
      read_notes = nullif(btrim(replace(read_notes, 'Copy loaded in the app from 9. Wolseley Sept 2026.pdf-2026-10-1 11.27.34.pdf.', '')), ''),
      updated_at = now()
    WHERE id = 2765;
    INSERT INTO audit_log (table_name, row_id, action, new_values)
    VALUES ('supplier_invoices', 2765, 'update', jsonb_build_object('copy_removed', '9. Wolseley Sept 2026.pdf (42 pages, put on the wrong invoice)'));
  END IF;
END $$;

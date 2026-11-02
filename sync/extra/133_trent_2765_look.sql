-- Look at Trent invoice #2765 before taking off the Wolseley copy that landed on it by mistake (a note in audit_log; changes nothing)
INSERT INTO audit_log (table_name, row_id, action, new_values)
SELECT 'supplier_invoices', 2765, 'update', jsonb_build_object('look', true, 
  'po_text', i.po_text, 'subtotal', i.subtotal, 'hst', i.hst, 'total', i.total, 'read_notes', i.read_notes,
  'lines_n', jsonb_array_length(coalesce(i.lines, '[]')), 'lines_head', left(coalesce(i.lines, '[]')::text, 600),
  'pages', (SELECT jsonb_agg(jsonb_build_array(page_no, kind, doc_number) ORDER BY page_no) FROM supplier_doc_pages WHERE supplier_invoice_id = 2765))
FROM supplier_invoices i WHERE i.id = 2765
  AND NOT EXISTS (SELECT 1 FROM audit_log WHERE table_name = 'supplier_invoices' AND row_id = 2765 AND new_values ? 'look');

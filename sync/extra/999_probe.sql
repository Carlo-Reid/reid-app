DO $$ BEGIN RAISE EXCEPTION 'PROBE n=% sum=% distinct=% | inv n=% sub=% tot=% | invsum=%',
  (SELECT count(*) FROM purchase_order_lines WHERE purchase_order_id = 29869), (SELECT sum(quantity * unit_cost) FROM purchase_order_lines WHERE purchase_order_id = 29869),
  (SELECT count(DISTINCT description || quantity || unit_cost) FROM purchase_order_lines WHERE purchase_order_id = 29869),
  (SELECT jsonb_array_length(lines) FROM supplier_invoices WHERE supplier_invoice_number = '40235866-00' LIMIT 1), (SELECT subtotal FROM supplier_invoices WHERE supplier_invoice_number = '40235866-00' LIMIT 1),
  (SELECT total FROM supplier_invoices WHERE supplier_invoice_number = '40235866-00' LIMIT 1),
  (SELECT sum((x ->> 'net_amount')::numeric) FROM supplier_invoices i, jsonb_array_elements(i.lines) x WHERE i.supplier_invoice_number = '40235866-00'); END $$;

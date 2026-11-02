DO $$ BEGIN RAISE EXCEPTION 'PROBE po: % | lines: % | inv lines: % | made: %',
  (SELECT string_agg(format('id=%s num=%s st=%s desc=%s', id, po_number, status, left(description, 40)), ' ; ') FROM purchase_orders WHERE po_number LIKE 'S-100%' OR description ILIKE '%40235866%'),
  (SELECT string_agg(format('%s x%s @%s', left(description, 25), quantity, unit_cost), ' | ') FROM purchase_order_lines WHERE purchase_order_id IN (SELECT id FROM purchase_orders WHERE po_number = 'S-1002')),
  (SELECT jsonb_array_length(lines) || ' sub=' || subtotal || ' tot=' || total FROM supplier_invoices WHERE supplier_invoice_number = '40235866-00' LIMIT 1),
  (SELECT count(*) FROM audit_log WHERE table_name = 'purchase_orders' AND new_values ? 'made_from_supplier_invoice'); END $$;

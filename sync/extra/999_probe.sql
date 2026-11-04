DO $$ BEGIN RAISE EXCEPTION 'PROBE %', (SELECT jsonb_build_object('auto', count(*) FILTER (WHERE auto), 'hand', count(*) FILTER (WHERE NOT auto),
  'cust_invoices', count(DISTINCT invoice_id), 'sup_invoices', count(DISTINCT supplier_invoice_id),
  'sup_total', (SELECT count(*) FROM supplier_invoices), 'sup_no_po_job', (SELECT count(*) FROM supplier_invoices s WHERE NOT EXISTS (SELECT 1 FROM purchase_orders po WHERE po.id = public._sinv_po(s) AND po.job_id IS NOT NULL)),
  'sup_job_no_inv', (SELECT count(*) FROM supplier_invoices s JOIN purchase_orders po ON po.id = public._sinv_po(s) WHERE po.job_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM invoices i WHERE i.job_id = po.job_id AND coalesce(i.status,'') <> 'void')))
  FROM supplier_invoice_customer_links)::text; END $$;

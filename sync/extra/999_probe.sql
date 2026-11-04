DO $$ DECLARE r text; BEGIN
CREATE TEMP TABLE _u ON COMMIT DROP AS
  SELECT s.id, s.supplier_id, s.doc_type, s.po_text, s.purchase_order_id, s.invoice_date, s.total, x.po_id, po.job_id,
         EXISTS (SELECT 1 FROM supplier_doc_pages p WHERE p.supplier_invoice_id = s.id) AS scanned
  FROM supplier_invoices s CROSS JOIN LATERAL (SELECT public._sinv_po(s) AS po_id) x LEFT JOIN purchase_orders po ON po.id = x.po_id
  WHERE po.job_id IS NULL;
SELECT jsonb_build_object(
  'pocols', (SELECT string_agg(column_name, ',') FROM information_schema.columns WHERE table_schema='public' AND table_name='purchase_orders'), 'cols', (SELECT string_agg(column_name, ',') FROM information_schema.columns WHERE table_schema='public' AND table_name='supplier_invoices'),
  'n', (SELECT count(*) FROM _u),
  'credit', (SELECT count(*) FROM _u WHERE doc_type = 'credit'),
  'po_no_job', (SELECT count(*) FROM _u WHERE po_id IS NOT NULL),
  'po_text_nomatch', (SELECT count(*) FROM _u WHERE po_id IS NULL AND nullif(btrim(coalesce(po_text,'')),'') IS NOT NULL),
  'nomatch_digits6', (SELECT count(*) FROM _u WHERE po_id IS NULL AND po_text ~ '[0-9]{6,}'),
  'no_po_text', (SELECT count(*) FROM _u WHERE po_id IS NULL AND nullif(btrim(coalesce(po_text,'')),'') IS NULL),
  'no_po_text_scanned', (SELECT count(*) FROM _u WHERE po_id IS NULL AND nullif(btrim(coalesce(po_text,'')),'') IS NULL AND scanned),
  'scanned', (SELECT count(*) FROM _u WHERE scanned),
  'years', (SELECT jsonb_object_agg(y, c) FROM (SELECT extract(year FROM invoice_date)::int y, count(*) c FROM _u GROUP BY 1) t),
  'by_sup', (SELECT jsonb_object_agg(n, c) FROM (SELECT left(btrim(sp.name),18) n, count(*) c FROM _u JOIN suppliers sp ON sp.id = _u.supplier_id GROUP BY 1 ORDER BY 2 DESC LIMIT 10) t),
  'sample_text', (SELECT string_agg(t, ' | ') FROM (SELECT left(po_text, 30) t FROM _u WHERE po_id IS NULL AND nullif(btrim(coalesce(po_text,'')),'') IS NOT NULL GROUP BY 1 ORDER BY count(*) DESC LIMIT 25) z),
  'po_no_job_sample', (SELECT string_agg(t, ' | ') FROM (SELECT po.po_number t FROM _u JOIN purchase_orders po ON po.id = _u.po_id LIMIT 8) z)
)::text INTO r;
RAISE EXCEPTION 'PROBE %', r; END $$;

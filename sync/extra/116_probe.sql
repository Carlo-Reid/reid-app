DO $$ BEGIN RAISE EXCEPTION 'PROBE kinds: % | linked: % | handwriting: %', (SELECT string_agg(coalesce(kind, 'null') || '=' || n, ', ') FROM (SELECT kind, count(*) n FROM supplier_doc_pages GROUP BY 1 ORDER BY 2 DESC) x),
  (SELECT string_agg(coalesce(kind, 'null') || '=' || n, ', ') FROM (SELECT kind, count(*) n FROM supplier_doc_pages WHERE supplier_invoice_id IS NOT NULL GROUP BY 1) x),
  (SELECT count(*) FROM supplier_invoices WHERE handwriting IS NOT NULL); END $$;

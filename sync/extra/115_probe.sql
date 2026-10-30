DO $$ BEGIN RAISE EXCEPTION 'PROBE %', (SELECT coalesce(string_agg(format('id=%s num=%s st=%s st_s=%s ord=%s sup=%s', id, po_number, st_id, status, ordered_at::date, supplier_id), ' ; '), 'NONE')
  FROM purchase_orders WHERE po_number LIKE '%93081855%' OR st_id = 93081855 OR supplier_reference LIKE '%93081855%')
  || ' || max st ord: ' || (SELECT max(ordered_at)::text FROM purchase_orders WHERE st_id IS NOT NULL)
  || ' || near: ' || (SELECT coalesce(string_agg(po_number, ',' ORDER BY po_number), '-') FROM (SELECT po_number FROM purchase_orders WHERE po_number ~ '^9308' ORDER BY po_number LIMIT 6) x); END $$;

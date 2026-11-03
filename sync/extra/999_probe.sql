DO $$ BEGIN RAISE EXCEPTION 'PROBE types: % | cand: %', (SELECT string_agg(entity_type || '=' || n, ',') FROM (SELECT entity_type, count(*) n FROM notes GROUP BY 1) x),
 (WITH o AS (SELECT i.id, i.invoice_number, i.balance_due, i.job_id, i.customer_id FROM invoices i WHERE i.balance_due > 0.004 AND i.status NOT IN ('void','draft')),
   m AS (SELECT DISTINCT o.id, n.entity_type FROM o JOIN notes n ON ((n.entity_type = 'invoice' AND n.entity_id = o.id) OR (n.entity_type = 'job' AND n.entity_id = o.job_id) OR (n.entity_type = 'customer' AND n.entity_id = o.customer_id))
     WHERE n.body ~* '\m(paid|e-?transfer|etransfer|cheque|check #|chq|visa|mastercard|amex|debit|cash|payment received|pd)\M'
       AND (n.body ILIKE '%' || o.invoice_number || '%' OR n.body ILIKE '%' || to_char(o.balance_due, 'FM999999990.00') || '%' OR n.entity_type IN ('invoice', 'job')))
   SELECT count(DISTINCT id) || ' invoices (' || string_agg(DISTINCT entity_type, '/') || ') of ' || (SELECT count(*) FROM o) || ' open' FROM m); END $$;

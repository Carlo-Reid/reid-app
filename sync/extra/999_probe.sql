DO $$ BEGIN RAISE EXCEPTION 'PROBE %', (WITH o AS (SELECT i.id, i.invoice_number, i.balance_due, i.job_id, i.customer_id, i.location_id FROM invoices i WHERE i.balance_due > 0.004 AND i.status NOT IN ('void','draft')),
   m AS (SELECT o.id, n.entity_type, o.invoice_number, left(regexp_replace(n.body, '\s+', ' ', 'g'), 60) b FROM o JOIN notes n ON ((n.entity_type = 'job' AND n.entity_id = o.job_id) OR (n.entity_type = 'customer' AND n.entity_id = o.customer_id) OR (n.entity_type = 'location' AND n.entity_id = o.location_id))
     WHERE n.body ~* '\m(paid|e-?transfer|etransfer|cheque|chq|visa|mastercard|amex|debit|payment)\M'
       AND (n.entity_type = 'job' OR n.body ILIKE '%' || o.invoice_number || '%' OR n.body ILIKE '%' || to_char(o.balance_due, 'FM999999990.00') || '%'))
   SELECT count(DISTINCT id) || ' | ' || string_agg(entity_type || ' ' || invoice_number || ': ' || b, ' ## ') FROM (SELECT * FROM m LIMIT 3) z); END $$;

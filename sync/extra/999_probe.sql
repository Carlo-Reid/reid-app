DO $$ DECLARE r text; BEGIN
WITH iv AS (SELECT i.id, i.subtotal, i.tax_total, i.total, i.amount_paid,
   (SELECT sum(line_total) FROM invoice_lines l WHERE l.invoice_id = i.id) ls, (SELECT sum(tax_amount) FROM invoice_lines l WHERE l.invoice_id = i.id) lt,
   (SELECT count(*) FILTER (WHERE line_total IS NULL) FROM invoice_lines l WHERE l.invoice_id = i.id) nnull,
   (SELECT sum(pa.amount) FROM payment_applications pa JOIN payments p ON p.id = pa.payment_id AND p.status = 'succeeded' WHERE pa.invoice_id = i.id) pd
   FROM invoices i WHERE i.st_id IS NOT NULL AND i.invoice_date >= '2025-01-01' AND i.status NOT IN ('void','draft'))
SELECT 'n=' || count(*) || ' linesum_off=' || count(*) FILTER (WHERE abs(coalesce(ls,0) - subtotal) > 0.01) || ' tax_off=' || count(*) FILTER (WHERE abs(coalesce(lt,0) - tax_total) > 0.01)
  || ' nulllines=' || sum(nnull) || ' paid_off=' || count(*) FILTER (WHERE abs(coalesce(pd,0) - amount_paid) > 0.01)
  || ' paid_off_owing=' || count(*) FILTER (WHERE abs(coalesce(pd,0) - amount_paid) > 0.01 AND total - amount_paid > 0.01)
  || ' paystatus=' || (SELECT string_agg(status || ':' || n, ',') FROM (SELECT p.status, count(*) n FROM payments p WHERE p.st_id IS NOT NULL GROUP BY 1) x)
  || ' ex=' || coalesce((SELECT string_agg(id || ' sub ' || subtotal || ' ls ' || coalesce(ls,0) || ' paid ' || amount_paid || ' pd ' || coalesce(pd,0), '; ') FROM (SELECT * FROM iv WHERE abs(coalesce(pd,0) - amount_paid) > 0.01 OR abs(coalesce(ls,0) - subtotal) > 0.01 LIMIT 6) z), '')
  || ' idseq=' || (SELECT pg_get_serial_sequence('invoice_lines','id')) || ' maxapp=' || (SELECT max(l.id) FROM invoice_lines l JOIN invoices i ON i.id = l.invoice_id WHERE i.st_id IS NULL) || ' minst=' || (SELECT min(id) FROM invoice_lines WHERE st_id IS NOT NULL) || ' st_eq_id=' || (SELECT count(*) FILTER (WHERE st_id = id) || '/' || count(*) FROM invoice_lines WHERE st_id IS NOT NULL)
INTO r FROM iv; RAISE EXCEPTION 'PROBE %', r; END $$;

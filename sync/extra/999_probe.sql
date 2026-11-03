DO $$ BEGIN RAISE EXCEPTION 'PROBE %', (
 SELECT jsonb_build_object(
  'files', (SELECT jsonb_agg(x) FROM (SELECT file_name, account, count(*) n, min(txn_date) d1, max(txn_date) d2, max(loaded_at)::date ld,
      count(*) FILTER (WHERE amount_in > 0 AND description ~* '^(VISTACREDIT|COSTCO|RONA INC|LOWE)') partner_dep,
      count(*) FILTER (WHERE EXISTS (SELECT 1 FROM bank_invoice_links k WHERE k.bank_id = b.id)) linked
     FROM bank_transactions b GROUP BY 1,2 ORDER BY max(loaded_at) DESC LIMIT 4) x),
  'links', (SELECT count(*) FROM bank_invoice_links), 'links_today', (SELECT count(*) FROM bank_invoice_links WHERE made_at > now() - interval '1 hour'),
  'top_desc_new', (SELECT string_agg(d, ' | ') FROM (SELECT left(description, 25) || ' x' || count(*) d FROM bank_transactions WHERE loaded_at > now() - interval '3 hours' AND amount_in > 0 GROUP BY left(description, 25) ORDER BY count(*) DESC LIMIT 8) s),
  'last_pay', (SELECT max(received_on) FROM payments WHERE st_id IS NOT NULL))::text); END $$;

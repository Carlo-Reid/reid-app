-- Bank: one search across both accounts: description, note, amount, the invoices tied to a line (number, customer, street),
-- supplier invoices and files attached to it
CREATE OR REPLACE FUNCTION public.bank_search(p_q text, p_limit int DEFAULT 200) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' SET statement_timeout TO '30s' AS $f$
DECLARE q text := nullif(btrim(coalesce(p_q, '')), ''); amt numeric; r jsonb;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can see the bank'; END IF;
  IF q IS NULL THEN RETURN jsonb_build_object('count', 0, 'rows', '[]'::jsonb); END IF;
  IF q ~ '^\$?[\d,]+(\.\d{1,2})?$' THEN amt := replace(replace(q, '$', ''), ',', '')::numeric; END IF;
  WITH hit AS (
    SELECT b.id FROM bank_transactions b
      WHERE (amt IS NOT NULL AND (b.amount_in = amt OR b.amount_out = amt)) OR b.description ILIKE '%' || q || '%' OR b.note ILIKE '%' || q || '%' OR b.code ILIKE q
    UNION SELECT k.bank_id FROM bank_invoice_links k JOIN invoices i ON i.id = k.invoice_id LEFT JOIN locations l ON l.id = i.location_id
      LEFT JOIN customers c ON c.id = l.customer_id LEFT JOIN customers c2 ON c2.id = i.customer_id
      WHERE i.invoice_number ILIKE q || '%' OR c.display_name ILIKE '%' || q || '%' OR c2.display_name ILIKE '%' || q || '%' OR l.street ILIKE '%' || q || '%' OR (amt IS NOT NULL AND (k.amount = amt OR i.total = amt))
    UNION SELECT s.bank_id FROM bank_sinv_links s JOIN supplier_invoices si ON si.id = s.supplier_invoice_id JOIN suppliers sp ON sp.id = si.supplier_id
      WHERE si.supplier_invoice_number ILIKE '%' || q || '%' OR sp.name ILIKE '%' || q || '%'
    UNION SELECT f.bank_id FROM bank_files f WHERE f.name ILIKE '%' || q || '%'),
  g AS (SELECT b.* FROM bank_transactions b JOIN hit USING (id))
  SELECT jsonb_build_object('count', (SELECT count(*) FROM g), 'in', (SELECT coalesce(sum(amount_in), 0) FROM g), 'out', (SELECT coalesce(sum(amount_out), 0) FROM g),
    'by_account', (SELECT coalesce(jsonb_object_agg(account, n), '{}') FROM (SELECT account, count(*) n FROM g GROUP BY account) a),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'account', x.account, 'date', x.txn_date, 'code', x.code, 'description', x.description, 'out', x.amount_out, 'in', x.amount_in,
               'balance', x.balance, 'note', x.note, 'cat', public._bank_cat(x.description, x.code, x.amount_in), 'transfer', public._bank_xfer(x.id), 'att', public._bank_att(x.id), 'ytd', public._bank_ytd(x.id),
               'invoices', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.invoice_number, 'date', i.invoice_date, 'amount', k.amount, 'how', k.how,
                              'who', coalesce((SELECT display_name FROM customers WHERE id = l.customer_id), c.display_name), 'street', l.street) ORDER BY i.invoice_date, i.invoice_number), '[]')
                            FROM bank_invoice_links k JOIN invoices i ON i.id = k.invoice_id LEFT JOIN customers c ON c.id = i.customer_id LEFT JOIN locations l ON l.id = i.location_id WHERE k.bank_id = x.id))
             ORDER BY x.txn_date DESC, x.id DESC), '[]')
             FROM (SELECT * FROM g ORDER BY txn_date DESC, id DESC LIMIT least(coalesce(p_limit, 200), 1000)) x)) INTO r;
  RETURN r;
END $f$;
REVOKE EXECUTE ON FUNCTION public.bank_search(text, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bank_search(text, int) TO authenticated;
NOTIFY pgrst, 'reload schema';

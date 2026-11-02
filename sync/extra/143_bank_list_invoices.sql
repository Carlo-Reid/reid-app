-- Bank transactions list: each line also carries the invoices it's tied to (shown on the right, like the Ledger)
DO $do$
DECLARE src text := pg_get_functiondef('public.bank_list(text, date, date, text, text, int, int, text)'::regprocedure);
BEGIN
  IF src LIKE '%bank_invoice_links%' THEN RETURN; END IF;
  src := replace(src, $a$'cat', cat, 'note', note)$a$, $a$'cat', cat, 'note', note,
      'invoices', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.invoice_number, 'date', i.invoice_date, 'amount', k.amount,
                     'who', coalesce((SELECT display_name FROM customers WHERE id = l.customer_id), c.display_name), 'street', l.street) ORDER BY i.invoice_date, i.invoice_number), '[]')
                   FROM bank_invoice_links k JOIN invoices i ON i.id = k.invoice_id LEFT JOIN customers c ON c.id = i.customer_id LEFT JOIN locations l ON l.id = i.location_id WHERE k.bank_id = x.id))$a$);
  IF src NOT LIKE '%bank_invoice_links%' THEN RAISE EXCEPTION 'bank_list: anchor not found'; END IF;
  EXECUTE src;
END $do$;
NOTIFY pgrst, 'reload schema';

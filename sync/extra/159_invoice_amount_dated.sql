-- Find by amount with dates picked: the exact search looks inside those dates (not just the newest 500 overall);
-- and the 3-5 search takes the newest invoices first when there are very many.
CREATE OR REPLACE FUNCTION public.invoice_amount_dated(p_amount numeric, p_from date, p_to date) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET statement_timeout TO '30s' AS $f$
  WITH m AS (SELECT i.* FROM invoices i WHERE public._amt_ok() AND i.status NOT IN ('void', 'draft')
               AND (p_from IS NULL OR i.invoice_date >= p_from) AND (p_to IS NULL OR i.invoice_date <= p_to)
               AND (i.total = round(p_amount, 2) OR i.amount_paid = round(p_amount, 2) OR i.balance_due = round(p_amount, 2))
               AND NOT EXISTS (SELECT 1 FROM bank_invoice_links k WHERE k.invoice_id = i.id))
  SELECT jsonb_build_object('n', (SELECT count(*) FROM m), 'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('invoice_id', x.id, 'invoice_number', x.invoice_number, 'invoice_date', x.invoice_date, 'status', x.status,
             'total', x.total, 'paid', x.amount_paid, 'balance', x.balance_due, 'on_total', x.total = round(p_amount, 2), 'on_paid', x.amount_paid = round(p_amount, 2), 'on_balance', x.balance_due = round(p_amount, 2),
             'customer_id', c.id, 'customer_name', c.display_name, 'customer_number', c.customer_number, 'street', l.street, 'city', l.city, 'job_type', t.name) ORDER BY x.invoice_date DESC)
    FROM (SELECT * FROM m ORDER BY invoice_date DESC LIMIT 500) x JOIN customers c ON c.id = x.customer_id
    LEFT JOIN locations l ON l.id = x.location_id LEFT JOIN jobs jb ON jb.id = x.job_id LEFT JOIN job_types t ON t.id = jb.job_type_id), '[]')) $f$;
REVOKE EXECUTE ON FUNCTION public.invoice_amount_dated(numeric, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invoice_amount_dated(numeric, date, date) TO authenticated;
DO $do$
DECLARE src text := pg_get_functiondef('public.invoice_amount_cands(numeric, text, date, date)'::regprocedure);
BEGIN
  IF src LIKE '%ORDER BY i.invoice_date DESC%' THEN RETURN; END IF;
  src := replace(src, '    LIMIT 40000) x)', '    ORDER BY i.invoice_date DESC LIMIT 40000) x)');
  IF src NOT LIKE '%ORDER BY i.invoice_date DESC%' THEN RAISE EXCEPTION 'invoice_amount_cands: anchor not found'; END IF;
  EXECUTE src;
END $do$;
NOTIFY pgrst, 'reload schema';

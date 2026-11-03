-- Find by amount: 3, 4 or 5 invoices that add up (the search runs in the browser on these candidates),
-- leaving out invoices whose money was already found in the bank; and the row details for what it finds.
CREATE OR REPLACE FUNCTION public._amt_ok() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT public.has_permission('invoices.adjust') OR coalesce(public.current_staff_role() IN ('owner', 'admin', 'accounting'), false) $f$;
CREATE OR REPLACE FUNCTION public.invoice_amount_cands(p_max numeric, p_field text DEFAULT 'total', p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET statement_timeout TO '30s' AS $f$
  SELECT CASE WHEN NOT public._amt_ok() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_array(x.id, x.invoice_date, x.c) ORDER BY x.invoice_date, x.id) FROM (
    SELECT i.id, i.invoice_date, round(CASE p_field WHEN 'balance' THEN i.balance_due WHEN 'paid' THEN i.amount_paid ELSE i.total END * 100)::bigint AS c
    FROM invoices i
    WHERE i.status NOT IN ('void', 'draft') AND i.invoice_date IS NOT NULL
      AND (p_from IS NULL OR i.invoice_date >= p_from) AND (p_to IS NULL OR i.invoice_date <= p_to)
      AND CASE p_field WHEN 'balance' THEN i.balance_due WHEN 'paid' THEN i.amount_paid ELSE i.total END BETWEEN 0.01 AND p_max - 0.01
      AND NOT EXISTS (SELECT 1 FROM bank_invoice_links k WHERE k.invoice_id = i.id)
    LIMIT 40000) x), '[]') END $f$;
CREATE OR REPLACE FUNCTION public.invoice_amount_rows(p_ids bigint[]) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._amt_ok() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('invoice_id', x.id, 'invoice_number', x.invoice_number, 'invoice_date', x.invoice_date, 'status', x.status,
             'total', x.total, 'paid', x.amount_paid, 'balance', x.balance_due,
             'customer_id', c.id, 'customer_name', c.display_name, 'customer_number', c.customer_number, 'street', l.street, 'city', l.city, 'job_type', t.name))
    FROM invoices x JOIN customers c ON c.id = x.customer_id
    LEFT JOIN locations l ON l.id = x.location_id LEFT JOIN jobs jb ON jb.id = x.job_id LEFT JOIN job_types t ON t.id = jb.job_type_id
    WHERE x.id = ANY (p_ids[1:3000])), '[]') END $f$;
-- which of these invoices already have their money found in the bank (left out of Find by amount)
CREATE OR REPLACE FUNCTION public.invoice_banked_ids(p_ids bigint[]) RETURNS bigint[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._amt_ok() THEN '{}'::bigint[] ELSE coalesce((SELECT array_agg(DISTINCT invoice_id) FROM bank_invoice_links WHERE invoice_id = ANY (p_ids[1:5000])), '{}') END $f$;
REVOKE EXECUTE ON FUNCTION public._amt_ok(), public.invoice_amount_cands(numeric, text, date, date), public.invoice_amount_rows(bigint[]), public.invoice_banked_ids(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invoice_amount_cands(numeric, text, date, date), public.invoice_amount_rows(bigint[]), public.invoice_banked_ids(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

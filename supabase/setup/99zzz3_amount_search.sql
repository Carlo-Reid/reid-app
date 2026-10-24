-- =====================================================================
-- Receivables: find by amount. Type an amount and see every invoice (any date, paid or not) whose total,
-- amount paid or balance owing is exactly that amount, to the cent. Same people as Receivables.
-- Safe to run more than once.
-- =====================================================================
CREATE INDEX IF NOT EXISTS invoices_total_idx ON public.invoices (total);
CREATE INDEX IF NOT EXISTS invoices_balance_idx ON public.invoices (balance_due);
CREATE INDEX IF NOT EXISTS invoices_paid_idx ON public.invoices (amount_paid);

CREATE OR REPLACE FUNCTION public.invoice_amount_search(p_amount numeric)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH a AS (SELECT round(p_amount, 2) AS v),
  hit AS (
    SELECT i.id FROM invoices i, a WHERE i.total = a.v
    UNION SELECT i.id FROM invoices i, a WHERE i.balance_due = a.v
    UNION SELECT i.id FROM invoices i, a WHERE i.amount_paid = a.v),
  p AS (
    SELECT i.* FROM invoices i JOIN hit h ON h.id = i.id
    WHERE (public.has_permission('invoices.adjust') OR coalesce(public.current_staff_role() IN ('owner', 'admin', 'accounting'), false))
      AND p_amount IS NOT NULL AND i.status NOT IN ('void', 'draft'))
  SELECT jsonb_build_object(
    'amount', (SELECT v FROM a),
    'n', (SELECT count(*) FROM p),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object(
               'invoice_id', x.id, 'invoice_number', x.invoice_number, 'invoice_date', x.invoice_date, 'status', x.status,
               'total', x.total, 'paid', x.amount_paid, 'balance', x.balance_due,
               'on_total', x.total = (SELECT v FROM a), 'on_paid', x.amount_paid = (SELECT v FROM a), 'on_balance', x.balance_due = (SELECT v FROM a),
               'customer_id', c.id, 'customer_name', c.display_name, 'customer_number', c.customer_number, 'street', l.street, 'city', l.city,
               'job_type', t.name) ORDER BY x.invoice_date DESC, x.id DESC), '[]')
             FROM (SELECT * FROM p ORDER BY invoice_date DESC, id DESC LIMIT 500) x
             JOIN customers c ON c.id = x.customer_id
             LEFT JOIN locations l ON l.id = x.location_id
             LEFT JOIN jobs j ON j.id = x.job_id
             LEFT JOIN job_types t ON t.id = j.job_type_id))
$$;
ALTER FUNCTION public.invoice_amount_search(numeric) SET jit = off;
REVOKE EXECUTE ON FUNCTION public.invoice_amount_search(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invoice_amount_search(numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';

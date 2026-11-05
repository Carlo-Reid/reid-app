-- Supplier invoices page: months after a supplier's newest statement (their invoices are in, the statement isn't yet), with what's owed so far:
-- the newest statement's balance, plus that month's invoices and credits, less what we've paid since the statement. Same people as the page.
CREATE OR REPLACE FUNCTION public.supplier_pending_months(p_supplier bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  WITH st AS (SELECT s.id, s.statement_date, s.total, s.aging FROM supplier_statements s WHERE s.supplier_id = p_supplier ORDER BY s.statement_date DESC, s.id DESC LIMIT 1),
       iv AS (SELECT i.* FROM supplier_invoices i WHERE i.supplier_id = p_supplier AND i.invoice_date IS NOT NULL AND i.total IS NOT NULL
                AND coalesce(i.doc_type, 'invoice') IN ('invoice', 'credit', 'charge') AND i.invoice_date > coalesce((SELECT statement_date FROM st), '1900-01-01'::date))
  SELECT CASE WHEN public.current_staff_role() IS NULL OR NOT (public._sinv_can_edit() OR public._can_see_costs()) THEN NULL ELSE jsonb_build_object(
    'last', (SELECT jsonb_build_object('id', id, 'date', statement_date, 'total', total, 'aging', aging) FROM st),
    'paid_since', coalesce((SELECT sum(p.amount) FROM supplier_payments p WHERE p.supplier_id = p_supplier AND p.voided_at IS NULL AND p.paid_on > coalesce((SELECT statement_date FROM st), '1900-01-01'::date)), 0),
    'months', coalesce((SELECT jsonb_agg(jsonb_build_object('month', m, 'n', n, 'total', t) ORDER BY m) FROM (SELECT to_char(invoice_date, 'YYYY-MM') AS m, count(*) AS n, sum(total) AS t FROM iv GROUP BY 1) z), '[]')) END $f$;
REVOKE EXECUTE ON FUNCTION public.supplier_pending_months(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_pending_months(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

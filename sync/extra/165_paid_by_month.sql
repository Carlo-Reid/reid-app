-- Receivables When tiles: what was paid each month of a year (the month tiles show it when Paid is pressed)
CREATE OR REPLACE FUNCTION public.paid_by_month(p_year int) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT (public.has_permission('invoices.adjust') OR coalesce(public.current_staff_role() IN ('owner', 'admin', 'accounting'), false)) THEN '{}'::jsonb ELSE
    coalesce((SELECT jsonb_object_agg(m, jsonb_build_object('n', n, 'total', t)) FROM (
      SELECT to_char(i.invoice_date, 'YYYY-MM') m, count(*) n, sum(i.total) t FROM invoices i
      WHERE i.balance_due <= 0.004 AND i.status NOT IN ('void', 'draft') AND i.invoice_date >= make_date(p_year, 1, 1) AND i.invoice_date < make_date(p_year + 1, 1, 1)
      GROUP BY 1) x), '{}') END $f$;
REVOKE EXECUTE ON FUNCTION public.paid_by_month(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.paid_by_month(int) TO authenticated;
NOTIFY pgrst, 'reload schema';

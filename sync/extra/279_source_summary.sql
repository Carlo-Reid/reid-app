-- Payroll → Source payment: the Paid list by year (George, Nov 13): for each month, the source paid, the gross payroll, and the
-- sales before HST from our invoices (the same invoices the Tax payments page counts: not void or draft, not paid at the store,
-- not a store's copy), so the page can show year to date, year over year, and payroll and source as a share of sales.
-- The months start a year before the first payment, so the first year has a year over year too.
-- A payment counts in the month its period starts in (Oct 1–15 and Oct 16–31 are both October). Owners only.
CREATE OR REPLACE FUNCTION public.source_summary() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off' AS $f$
DECLARE f date; t date;
BEGIN
  IF NOT public._src_owner() THEN RETURN NULL; END IF;
  SELECT (date_trunc('year', min(period_from)) - interval '1 year')::date INTO f FROM source_remits WHERE pdf IS NOT NULL OR total IS NOT NULL;
  IF f IS NULL THEN RETURN '[]'::jsonb; END IF;
  t := (date_trunc('month', public._src_today()) + interval '1 month - 1 day')::date;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('m', to_char(m, 'YYYY-MM'), 'source', s.source, 'gross', s.gross, 'n', coalesce(s.n, 0), 'sales', v.sales) ORDER BY m)
    FROM generate_series(f, t, interval '1 month') m
    LEFT JOIN LATERAL (SELECT sum(coalesce(r.paid_amount, r.total)) FILTER (WHERE r.pdf IS NOT NULL) AS source, sum(r.gross) AS gross,
                              count(*) FILTER (WHERE r.pdf IS NOT NULL) AS n
                         FROM source_remits r WHERE r.period_from >= m::date AND r.period_from < (m + interval '1 month')::date) s ON true
    LEFT JOIN LATERAL (SELECT sum(i.subtotal) AS sales FROM invoices i
                        WHERE i.status NOT IN ('void', 'draft') AND NOT coalesce(i.paid_at_store, false) AND i.store_copy_of IS NULL
                          AND i.invoice_date >= m::date AND i.invoice_date < (m + interval '1 month')::date) v ON true), '[]'::jsonb);
END $f$;
REVOKE EXECUTE ON FUNCTION public.source_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.source_summary() TO authenticated;
NOTIFY pgrst, 'reload schema';

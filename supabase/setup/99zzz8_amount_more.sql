-- =====================================================================
-- Receivables, Find by amount: two more ways to look.
--   invoice_amount_near:  every invoice whose total, amount paid or balance owing is within p_range (default $100)
--                         above or below the amount, closest first.
--   invoice_amount_pairs: two invoices of the SAME customer whose totals (or balances owing, or amounts paid) add up to
--                         exactly the amount; the ones closest together in date first.
-- Same people as Receivables. Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.invoice_amount_near(p_amount numeric, p_range numeric DEFAULT 100)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '30s' AS $$
  WITH a AS (SELECT round(p_amount, 2) AS v, least(greatest(abs(coalesce(p_range, 100)), 0.01), 10000) AS d),
  hit AS (
    SELECT i.id FROM invoices i, a WHERE i.total BETWEEN a.v - a.d AND a.v + a.d
    UNION SELECT i.id FROM invoices i, a WHERE i.balance_due BETWEEN a.v - a.d AND a.v + a.d AND i.balance_due > 0.004
    UNION SELECT i.id FROM invoices i, a WHERE i.amount_paid BETWEEN a.v - a.d AND a.v + a.d AND i.amount_paid > 0.004),
  p AS (
    SELECT i.*, least(abs(i.total - a.v), CASE WHEN i.balance_due > 0.004 THEN abs(i.balance_due - a.v) END,
                      CASE WHEN i.amount_paid > 0.004 THEN abs(i.amount_paid - a.v) END) AS diff
    FROM invoices i JOIN hit h ON h.id = i.id, a
    WHERE (public.has_permission('invoices.adjust') OR coalesce(public.current_staff_role() IN ('owner', 'admin', 'accounting'), false))
      AND p_amount IS NOT NULL AND i.status NOT IN ('void', 'draft'))
  SELECT jsonb_build_object(
    'amount', (SELECT v FROM a), 'range', (SELECT d FROM a),
    'n', (SELECT count(*) FROM p),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object(
               'invoice_id', x.id, 'invoice_number', x.invoice_number, 'invoice_date', x.invoice_date, 'status', x.status,
               'total', x.total, 'paid', x.amount_paid, 'balance', x.balance_due, 'diff', x.diff,
               'on_total', abs(x.total - (SELECT v FROM a)) = x.diff, 'on_paid', x.amount_paid > 0.004 AND abs(x.amount_paid - (SELECT v FROM a)) = x.diff,
               'on_balance', x.balance_due > 0.004 AND abs(x.balance_due - (SELECT v FROM a)) = x.diff,
               'customer_id', c.id, 'customer_name', c.display_name, 'customer_number', c.customer_number, 'street', l.street, 'city', l.city,
               'job_type', t.name) ORDER BY x.diff, x.invoice_date DESC, x.id DESC), '[]')
             FROM (SELECT * FROM p ORDER BY diff, invoice_date DESC, id DESC LIMIT 500) x
             JOIN customers c ON c.id = x.customer_id
             LEFT JOIN locations l ON l.id = x.location_id
             LEFT JOIN jobs j ON j.id = x.job_id
             LEFT JOIN job_types t ON t.id = j.job_type_id))
$$;

-- p_field: 'total' (the invoice totals), 'balance' (what's still owed) or 'paid' (what was paid on them)
CREATE OR REPLACE FUNCTION public.invoice_amount_pairs(p_amount numeric, p_field text DEFAULT 'total')
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '30s' AS $$
DECLARE v numeric := round(p_amount, 2); f text := CASE WHEN p_field IN ('total', 'balance', 'paid') THEN p_field ELSE 'total' END; r jsonb;
BEGIN
  IF NOT (public.has_permission('invoices.adjust') OR coalesce(public.current_staff_role() IN ('owner', 'admin', 'accounting'), false)) OR v IS NULL OR v <= 0 THEN
    RETURN jsonb_build_object('amount', v, 'field', f, 'n', 0, 'rows', '[]'::jsonb);
  END IF;
  WITH inv AS MATERIALIZED (
    SELECT i.id, i.customer_id, i.invoice_date, CASE f WHEN 'balance' THEN i.balance_due WHEN 'paid' THEN i.amount_paid ELSE i.total END AS amt
    FROM invoices i
    WHERE i.status NOT IN ('void', 'draft')
      AND CASE f WHEN 'balance' THEN i.balance_due WHEN 'paid' THEN i.amount_paid ELSE i.total END BETWEEN 0.01 AND v - 0.01),
  pr AS (
    SELECT a.id AS a_id, b.id AS b_id, (a.customer_id = b.customer_id) AS same, abs(a.invoice_date - b.invoice_date) AS gap
    FROM inv a JOIN inv b ON b.customer_id = a.customer_id AND b.amt = v - a.amt AND (a.amt < b.amt OR (a.amt = b.amt AND a.id < b.id))
    LIMIT 20000),
  top AS (SELECT * FROM pr ORDER BY gap NULLS LAST, a_id DESC LIMIT 200),
  one AS (
    SELECT x.id, jsonb_build_object('invoice_id', x.id, 'invoice_number', x.invoice_number, 'invoice_date', x.invoice_date, 'status', x.status,
             'total', x.total, 'paid', x.amount_paid, 'balance', x.balance_due,
             'customer_id', c.id, 'customer_name', c.display_name, 'customer_number', c.customer_number, 'street', l.street, 'city', l.city, 'job_type', t.name) AS j
    FROM invoices x JOIN customers c ON c.id = x.customer_id
    LEFT JOIN locations l ON l.id = x.location_id LEFT JOIN jobs jb ON jb.id = x.job_id LEFT JOIN job_types t ON t.id = jb.job_type_id
    WHERE x.id IN (SELECT a_id FROM top UNION SELECT b_id FROM top))
  SELECT jsonb_build_object('amount', v, 'field', f, 'n', (SELECT count(*) FROM pr), 'capped', (SELECT count(*) FROM pr) >= 20000,
           'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('same', t.same, 'gap', t.gap, 'a', oa.j, 'b', ob.j) ORDER BY t.gap NULLS LAST, t.a_id DESC)
                             FROM top t JOIN one oa ON oa.id = t.a_id JOIN one ob ON ob.id = t.b_id), '[]'))
  INTO r;
  RETURN r;
END $$;

ALTER FUNCTION public.invoice_amount_near(numeric, numeric) SET jit = off;
ALTER FUNCTION public.invoice_amount_pairs(numeric, text) SET jit = off;
REVOKE EXECUTE ON FUNCTION public.invoice_amount_near(numeric, numeric), public.invoice_amount_pairs(numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invoice_amount_near(numeric, numeric), public.invoice_amount_pairs(numeric, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

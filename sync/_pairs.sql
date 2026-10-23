CREATE FUNCTION pg_temp.pairs_a(p_amount numeric, p_field text DEFAULT 'total')
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '30s' AS $$
DECLARE v numeric := round(p_amount, 2); f text := CASE WHEN p_field IN ('total', 'balance', 'paid') THEN p_field ELSE 'total' END; r jsonb;
BEGIN
  IF v IS NULL OR v <= 0 THEN
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
CREATE FUNCTION pg_temp.pairs_b(p_amount numeric, p_field text DEFAULT 'total') RETURNS int LANGUAGE sql STABLE AS $$
  SELECT count(*)::int FROM invoices a JOIN invoices b ON b.customer_id = a.customer_id AND b.id <> a.id
  WHERE a.status NOT IN ('void','draft') AND b.status NOT IN ('void','draft') AND a.total BETWEEN 0.01 AND p_amount - 0.01
    AND b.total = round(p_amount, 2) - a.total AND (a.total < b.total OR (a.total = b.total AND a.id < b.id)) $$;
-- Vista: old jobs billed as two invoices, one for our labour (Vista pays us) and one for the tank (Vista pays our supplier).
-- The tank invoice gets a "partner pays supplier" record for its amount, tied to the labour invoice it goes with,
-- so the pair shows together (Vista page, both invoices, the customer's file) and the tank isn't counted as owed to us.
ALTER TABLE public.third_party_supplier_payments ADD COLUMN IF NOT EXISTS goes_with_invoice_id bigint REFERENCES public.invoices(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS tpsp_goes_with ON public.third_party_supplier_payments (goes_with_invoice_id);

-- "not a pair": a suggestion you said no to doesn't come back
CREATE TABLE IF NOT EXISTS public.vista_tank_not_pairs (tank_id bigint PRIMARY KEY REFERENCES public.invoices(id) ON DELETE CASCADE, by_user bigint, at timestamptz DEFAULT now());
ALTER TABLE public.vista_tank_not_pairs ENABLE ROW LEVEL SECURITY;

-- the pairs: tied ones, and ones that look like a pair (a second invoice on the same job with no price book items on it)
CREATE OR REPLACE FUNCTION public.vista_tank_pairs(p_partner bigint, p_show text DEFAULT 'suggested')
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH v AS (SELECT i.* FROM invoices i WHERE i.bill_to_partner_id = p_partner AND i.status NOT IN ('void', 'draft') AND i.total > 0),
  has_item AS (SELECT DISTINCT il.invoice_id FROM invoice_lines il JOIN v ON v.id = il.invoice_id WHERE il.item_id IS NOT NULL AND coalesce(il.unit_price, 0) > 0),
  tied AS (SELECT t.id AS sp_id, t.invoice_id AS tank_id, t.goes_with_invoice_id AS labour_id, t.supplier_id, t.amount, t.status, t.paid_on FROM third_party_supplier_payments t
           WHERE t.partner_id = p_partner AND t.goes_with_invoice_id IS NOT NULL),
  sug AS (SELECT DISTINCT ON (tk.id) tk.id AS tank_id, lb.id AS labour_id FROM v tk JOIN v lb ON lb.job_id = tk.job_id AND lb.id <> tk.id
          WHERE tk.id NOT IN (SELECT invoice_id FROM has_item) AND lb.id IN (SELECT invoice_id FROM has_item)
            AND NOT EXISTS (SELECT 1 FROM third_party_supplier_payments x WHERE x.invoice_id IN (tk.id, lb.id))
            AND NOT EXISTS (SELECT 1 FROM vista_tank_not_pairs np WHERE np.tank_id = tk.id)
          ORDER BY tk.id, abs(lb.invoice_date - tk.invoice_date), lb.id),
  rr AS (SELECT 'tied' AS kind, sp_id, tank_id, labour_id, supplier_id, amount, status, paid_on FROM tied WHERE coalesce(p_show, 'suggested') IN ('tied', 'all')
           UNION ALL SELECT 'suggested', NULL, tank_id, labour_id, NULL, NULL, NULL, NULL FROM sug WHERE coalesce(p_show, 'suggested') IN ('suggested', 'all'))
  SELECT CASE WHEN NOT public._can_partner_pay() THEN NULL ELSE coalesce(jsonb_agg(jsonb_build_object(
    'kind', r.kind, 'sp_id', r.sp_id, 'supplier_id', r.supplier_id, 'supplier', (SELECT name FROM suppliers WHERE id = r.supplier_id), 'amount', r.amount, 'status', r.status, 'paid_on', r.paid_on,
    'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'job_number', j.job_number,
    'tank', jsonb_build_object('id', tk.id, 'number', tk.invoice_number, 'date', tk.invoice_date, 'total', tk.total, 'balance', tk.balance_due,
             'what', (SELECT string_agg(btrim(regexp_replace(split_part(il.description, E'\n', 1), '^Note:\s*', '')), ' · ') FROM invoice_lines il WHERE il.invoice_id = tk.id AND coalesce(il.line_total, 0) <> 0)),
    'labour', jsonb_build_object('id', lb.id, 'number', lb.invoice_number, 'date', lb.invoice_date, 'total', lb.total, 'balance', lb.balance_due,
             'what', (SELECT string_agg(split_part(il.description, E'\n', 1), ' · ' ORDER BY il.line_total DESC) FROM (SELECT * FROM invoice_lines il2 WHERE il2.invoice_id = lb.id AND coalesce(il2.line_total, 0) > 0 ORDER BY il2.line_total DESC LIMIT 2) il)))
    ORDER BY tk.invoice_date DESC, tk.id DESC), '[]') END
  FROM rr r JOIN invoices tk ON tk.id = r.tank_id LEFT JOIN invoices lb ON lb.id = r.labour_id
  LEFT JOIN jobs j ON j.id = tk.job_id LEFT JOIN customers c ON c.id = tk.customer_id LEFT JOIN locations l ON l.id = tk.location_id
$function$;


-- tie a tank invoice to its labour invoice (Vista pays this supplier the tank invoice's amount), or untie it
CREATE OR REPLACE FUNCTION public.vista_tank_tie(p_tank bigint, p_labour bigint, p_supplier bigint, p_amount numeric DEFAULT NULL, p_action text DEFAULT 'tie')
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE t invoices; lb invoices; o third_party_supplier_payments;
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'Only the office can change this'; END IF;
  SELECT * INTO t FROM invoices WHERE id = p_tank; IF t.id IS NULL THEN RAISE EXCEPTION 'That tank invoice isn''t there'; END IF;
  IF p_action = 'not_pair' THEN INSERT INTO vista_tank_not_pairs (tank_id, by_user) VALUES (p_tank, public.current_app_user_id()) ON CONFLICT DO NOTHING; RETURN; END IF;
  SELECT * INTO o FROM third_party_supplier_payments WHERE invoice_id = p_tank;
  IF p_action = 'untie' THEN
    IF o.id IS NOT NULL AND o.status <> 'submitted' THEN RAISE EXCEPTION 'Vista already paid the supplier for it. Set it back to the first step first'; END IF;
    DELETE FROM third_party_supplier_payments WHERE invoice_id = p_tank;
  ELSE
    SELECT * INTO lb FROM invoices WHERE id = p_labour;
    IF lb.id IS NULL THEN RAISE EXCEPTION 'Pick the labour invoice it goes with'; END IF;
    IF lb.id = t.id THEN RAISE EXCEPTION 'The tank and labour invoices are the same one'; END IF;
    IF t.bill_to_partner_id IS NULL THEN RAISE EXCEPTION 'The tank invoice isn''t billed to the partner'; END IF;
    IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier) THEN RAISE EXCEPTION 'Pick the supplier Vista pays'; END IF;
    INSERT INTO third_party_supplier_payments (invoice_id, job_id, partner_id, supplier_id, amount, created_by, goes_with_invoice_id)
    VALUES (t.id, t.job_id, t.bill_to_partner_id, p_supplier, round(coalesce(p_amount, t.total), 2), public.current_app_user_id(), lb.id)
    ON CONFLICT (invoice_id) WHERE invoice_id IS NOT NULL DO UPDATE SET supplier_id = EXCLUDED.supplier_id, amount = EXCLUDED.amount, goes_with_invoice_id = EXCLUDED.goes_with_invoice_id;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('invoices', p_tank, 'update', public.current_app_user_id(), jsonb_build_object('vista_tank', p_action, 'labour_invoice', p_labour, 'supplier_id', p_supplier));
END $function$;

-- the pair an invoice belongs to (either side), for the invoice and the customer's file
CREATE OR REPLACE FUNCTION public.invoice_tank_pairs(p_invoices bigint[])
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce(jsonb_agg(jsonb_build_object(
    'tank_id', t.invoice_id, 'tank_number', tk.invoice_number, 'tank_total', tk.total, 'labour_id', t.goes_with_invoice_id, 'labour_number', lb.invoice_number, 'labour_total', lb.total,
    'labour_balance', lb.balance_due, 'partner', p.name, 'supplier', s.name, 'amount', t.amount, 'status', t.status, 'paid_on', t.paid_on)), '[]') END
  FROM third_party_supplier_payments t JOIN invoices tk ON tk.id = t.invoice_id LEFT JOIN invoices lb ON lb.id = t.goes_with_invoice_id
  JOIN suppliers s ON s.id = t.supplier_id JOIN partners p ON p.id = t.partner_id
  WHERE t.goes_with_invoice_id IS NOT NULL AND (t.invoice_id = ANY (p_invoices[1:500]) OR t.goes_with_invoice_id = ANY (p_invoices[1:500]))
$function$;

REVOKE EXECUTE ON FUNCTION public.vista_tank_pairs(bigint, text), public.vista_tank_tie(bigint, bigint, bigint, numeric, text), public.invoice_tank_pairs(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vista_tank_pairs(bigint, text), public.vista_tank_tie(bigint, bigint, bigint, numeric, text), public.invoice_tank_pairs(bigint[]) TO authenticated;

-- Receivables: a tank invoice Vista pays our supplier for in full isn't money owed to us
DO $$ DECLARE s text; BEGIN
  SELECT pg_get_functiondef('public.open_balances(text, text)'::regprocedure) INTO s;
  IF position('third_party_supplier_payments' IN s) = 0 THEN
    s := replace(s, 'AND i.balance_due > 0.004 AND i.status NOT IN (''void'', ''draft'')',
      'AND i.balance_due > 0.004 AND i.status NOT IN (''void'', ''draft'')
    AND NOT EXISTS (SELECT 1 FROM third_party_supplier_payments sp WHERE sp.invoice_id = i.id AND sp.goes_with_invoice_id IS NOT NULL AND sp.amount >= i.balance_due - 0.01)');
    EXECUTE s;
  END IF;
END $$;
NOTIFY pgrst, 'reload schema';

-- Invoice tax is worked out AFTER discounts, like ServiceTitan: 13% of (items - discounts), rounded once.
-- (Before, discount lines were "not taxable" so tax was 13% of the full price: e.g. invoice 15054715 showed $1,103.70 instead of $821.15
--  and a paid invoice looked $282.55 short.) Only invoices with discount lines change; others keep the line-by-line tax.
CREATE OR REPLACE FUNCTION public._inv_tax(p_invoice bigint) RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public' AS $f$
  WITH l AS (SELECT line_type, taxable, tax_rate_pct, line_total, tax_amount FROM invoice_lines WHERE invoice_id = p_invoice),
  s AS (SELECT
      coalesce(sum(tax_amount), 0) AS line_tax,
      coalesce(sum(line_total) FILTER (WHERE line_type = 'discount' AND NOT taxable AND line_total < 0), 0) AS disc,            -- discounts not already taxed
      coalesce(sum(line_total) FILTER (WHERE line_type <> 'discount' AND line_total > 0), 0) AS items,
      coalesce(sum(line_total) FILTER (WHERE taxable), 0) AS taxable_sum,
      coalesce(sum(line_total) FILTER (WHERE taxable AND line_type <> 'discount' AND line_total > 0), 0) AS taxable_items,
      max(tax_rate_pct) FILTER (WHERE taxable AND line_total <> 0) AS rate
    FROM l)
  SELECT CASE WHEN disc < 0 AND items > 0 AND rate > 0
              THEN greatest(round((taxable_sum + disc * taxable_items / items) * rate / 100, 2), 0)   -- the discount lowers the taxed amount (its taxable share)
              ELSE line_tax END
  FROM s
$f$;

CREATE OR REPLACE FUNCTION public.recalc_invoice(p_invoice bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_tax numeric := public._inv_tax(p_invoice);
BEGIN
  UPDATE invoices i SET
    subtotal  = coalesce(x.sub, 0),
    tax_total = v_tax,
    total     = coalesce(x.sub, 0) + v_tax,
    amount_paid = coalesce(p.paid, 0),
    status = CASE
      WHEN i.status IN ('draft','void') THEN i.status
      WHEN coalesce(p.paid,0) >= coalesce(x.sub,0) + v_tax AND coalesce(x.sub,0) + v_tax > 0 THEN 'paid'
      WHEN coalesce(p.paid,0) > 0 THEN 'partially_paid'
      WHEN i.status IN ('paid','partially_paid') THEN 'posted'
      ELSE i.status END
  FROM (SELECT sum(line_total) sub FROM invoice_lines WHERE invoice_id = p_invoice) x,
       (SELECT sum(pa.amount) paid FROM payment_applications pa
          JOIN payments py ON py.id = pa.payment_id AND py.status = 'succeeded'
        WHERE pa.invoice_id = p_invoice) p
  WHERE i.id = p_invoice;
END $$;

-- owners: what the fix changes on invoices already saved (looked at before it's applied)
CREATE OR REPLACE FUNCTION public.tax_fix_preview() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RETURN NULL; END IF;
  RETURN (WITH c AS (
      SELECT i.id, i.invoice_number, i.invoice_date, i.tax_total AS was, public._inv_tax(i.id) AS now_tax, i.amount_paid, i.subtotal, i.status
      FROM invoices i WHERE i.status NOT IN ('void', 'draft') AND EXISTS (SELECT 1 FROM invoice_lines l WHERE l.invoice_id = i.id AND l.line_type = 'discount' AND NOT l.taxable AND l.line_total < 0))
    SELECT jsonb_build_object('invoices', count(*) FILTER (WHERE was <> now_tax),
      'tax_down', sum(was - now_tax) FILTER (WHERE was > now_tax), 'tax_up', sum(now_tax - was) FILTER (WHERE now_tax > was),
      'fully_paid_after', count(*) FILTER (WHERE was <> now_tax AND abs(subtotal + now_tax - amount_paid) < 0.005),
      'owing_before', count(*) FILTER (WHERE was <> now_tax AND subtotal + was - amount_paid > 0.005),
      'owing_after', count(*) FILTER (WHERE was <> now_tax AND subtotal + now_tax - amount_paid > 0.005),
      'sample', (SELECT jsonb_agg(x) FROM (SELECT invoice_number, invoice_date, was, now_tax, amount_paid, subtotal FROM c WHERE was <> now_tax ORDER BY invoice_date DESC LIMIT 12) x),
      'check_15054715', (SELECT jsonb_build_object('was', was, 'now', now_tax) FROM c WHERE invoice_number = '15054715'))
    FROM c);
END $f$;
REVOKE EXECUTE ON FUNCTION public.tax_fix_preview() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tax_fix_preview() TO authenticated;
NOTIFY pgrst, 'reload schema';

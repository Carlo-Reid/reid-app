-- Find our invoice (on an open supplier invoice or credit) also looks by amount (Carlo, Nov 12, 2026: "have the Find our invoice also search by
-- amount so you can search by the credit amount to see what it may match"). Words typed as an amount (with cents: 691.56, $1,654.32, -691.56)
-- find our invoices whose total or before-tax amount is that amount, or that amount with or without 13% HST. Anything else searches as before.
CREATE OR REPLACE FUNCTION public.sinv_cust_find(p_q text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE q text := nullif(btrim(coalesce(p_q, '')), ''); a numeric;
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  IF q IS NULL OR length(q) < 2 THEN RETURN '[]'::jsonb; END IF;
  IF q ~ '^-?\$?-?[0-9][0-9,]*\.[0-9]{1,2}-?$' THEN
    a := abs(replace(replace(replace(q, '$', ''), ',', ''), '-', '')::numeric);
    RETURN (SELECT coalesce(jsonb_agg(public._sinv_cinv(x) ORDER BY x.invoice_date DESC, x.id DESC), '[]') FROM (
      SELECT i.* FROM invoices i
      WHERE coalesce(i.status, '') <> 'void' AND a > 0
        AND (abs(i.total) IN (a, round(a * 1.13, 2), round(a / 1.13, 2)) OR abs(i.subtotal) IN (a, round(a / 1.13, 2)))
      ORDER BY (abs(i.total) = a) DESC, i.invoice_date DESC NULLS LAST, i.id DESC LIMIT 20) x);
  END IF;
  RETURN (SELECT coalesce(jsonb_agg(public._sinv_cinv(x) ORDER BY x.invoice_date DESC, x.id DESC), '[]') FROM (
    SELECT i.* FROM invoices i LEFT JOIN locations l ON l.id = i.location_id LEFT JOIN customers c ON c.id = coalesce(l.customer_id, i.customer_id) LEFT JOIN jobs j ON j.id = i.job_id
    WHERE coalesce(i.status, '') <> 'void' AND (i.invoice_number ILIKE q || '%' OR j.job_number ILIKE q || '%' OR c.display_name ILIKE '%' || q || '%' OR l.street ILIKE '%' || q || '%')
    ORDER BY (i.invoice_number = q) DESC, i.invoice_date DESC NULLS LAST, i.id DESC LIMIT 12) x);
END $function$;

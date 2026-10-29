-- Customer loyalty rebate: $50 for every full year since their first invoice, up to $1000
CREATE OR REPLACE FUNCTION public.customer_loyalty(p_customer bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_since date; v_years int;
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN NULL; END IF;
  SELECT least(min(i.invoice_date), (SELECT c.became_customer_at::date FROM customers c WHERE c.id = p_customer)) INTO v_since
  FROM invoices i WHERE i.customer_id = p_customer AND i.status NOT IN ('void', 'draft');
  IF v_since IS NULL THEN SELECT c.became_customer_at::date INTO v_since FROM customers c WHERE c.id = p_customer; END IF;
  v_years := CASE WHEN v_since IS NULL THEN 0 ELSE extract(year FROM age((now() AT TIME ZONE 'America/Toronto')::date, v_since))::int END;
  RETURN jsonb_build_object('since', v_since, 'years', v_years, 'amount', least(greatest(v_years, 0) * 50, 1000));
END $function$;
REVOKE EXECUTE ON FUNCTION public.customer_loyalty(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_loyalty(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

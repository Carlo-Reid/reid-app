-- Job costs: how many techs the labour is counted for, set by hand on the invoice's Job costs tab
-- (Carlo, Nov 16, 2026: "have a way to add a second tech to the side bar"). Empty = the usual count.
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS cost_techs integer;

CREATE OR REPLACE FUNCTION public.inv_set_cost_techs(p_invoice bigint, p_n integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i invoices;
BEGIN
  IF NOT public._can_cost() THEN RAISE EXCEPTION 'You don''t have permission to see job costing'; END IF;
  SELECT * INTO i FROM invoices WHERE id = p_invoice;
  IF i.id IS NULL THEN RAISE EXCEPTION 'That invoice no longer exists'; END IF;
  IF p_n IS NOT NULL AND (p_n < 1 OR p_n > 6) THEN RAISE EXCEPTION 'Pick 1 to 6 techs'; END IF;
  UPDATE invoices SET cost_techs = p_n WHERE id = p_invoice;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('invoices', p_invoice, 'update', public.current_app_user_id(), jsonb_build_object('cost_techs', i.cost_techs), jsonb_build_object('cost_techs', p_n));
END $function$;
REVOKE EXECUTE ON FUNCTION public.inv_set_cost_techs(bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inv_set_cost_techs(bigint, integer) TO authenticated;

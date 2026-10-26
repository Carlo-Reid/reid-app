-- Invoice look: a sales person can only pick Reid or a partner they're allowed to sell for (Staff page, "Sales call for").
-- Same as 49_invoice_from.sql otherwise. Safe to run more than once.
CREATE OR REPLACE FUNCTION public.inv_set_look(p_invoice bigint, p_partner bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE i invoices; v_store boolean; v_allowed bigint[];
BEGIN
  SELECT * INTO i FROM invoices WHERE id = p_invoice;
  IF i.id IS NULL THEN RAISE EXCEPTION 'That invoice no longer exists'; END IF;
  IF NOT public._can_change_look(p_invoice) THEN RAISE EXCEPTION 'Only the office can change who this invoice is from'; END IF;
  IF p_partner IS NOT NULL AND public.current_staff_role() = 'sales' THEN
    SELECT sales_for INTO v_allowed FROM app_users WHERE id = public.current_app_user_id();
    IF v_allowed IS NOT NULL AND NOT (p_partner = ANY (v_allowed)) THEN RAISE EXCEPTION 'You can''t use that partner. Ask the office.'; END IF;
  END IF;
  SELECT customer_pays_partner INTO v_store FROM partners WHERE id = p_partner;
  UPDATE invoices SET look = CASE WHEN p_partner IS NULL THEN 'reid' ELSE 'store' END,
         branding_partner_id = p_partner,
         bill_to_partner_id = CASE WHEN p_partner IS NOT NULL AND v_store THEN p_partner
                                   WHEN EXISTS (SELECT 1 FROM partners p WHERE p.id = i.bill_to_partner_id AND p.customer_pays_partner) THEN NULL
                                   ELSE bill_to_partner_id END
  WHERE id = i.id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('invoices', i.id, 'update', public.current_app_user_id(),
          jsonb_build_object('from', coalesce((SELECT name FROM partners WHERE id = coalesce(i.branding_partner_id, i.bill_to_partner_id)), 'Reid')),
          jsonb_build_object('from', coalesce((SELECT name FROM partners WHERE id = p_partner), 'Reid')));
END $$;
NOTIFY pgrst, 'reload schema';

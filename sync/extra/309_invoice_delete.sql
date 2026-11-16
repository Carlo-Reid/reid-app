-- Customer page: delete an invoice (Carlo, Nov 16, 2026). Owners only. Safe to run more than once.
-- An invoice made in the app is erased for good (what it was is kept in the history, audit_log).
-- An invoice that came from ServiceTitan can not be erased (the next sync would bring it back), so it is
-- marked Void, hidden from the customer's page (deleted_at) and the sync is told to leave it alone (app_edited_at).
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS deleted_by bigint;

CREATE OR REPLACE FUNCTION public.invoice_delete(p_id bigint, p_dry boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i invoices; why text; n_lines int; n_tank int; v_st boolean;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only an owner can delete an invoice'; END IF;
  SELECT * INTO i FROM invoices WHERE id = p_id; IF i.id IS NULL THEN RAISE EXCEPTION 'That invoice isn''t there any more'; END IF;
  v_st := i.st_id IS NOT NULL;
  why := CASE
    WHEN i.store_copy_of IS NOT NULL THEN 'it is the store''s copy of a customer''s invoice (delete the customer''s invoice instead)'
    WHEN EXISTS (SELECT 1 FROM invoices x WHERE x.store_copy_of = p_id AND x.status <> 'void') THEN 'a store''s copy was made from it'
    WHEN EXISTS (SELECT 1 FROM payment_applications WHERE invoice_id = p_id) THEN 'a payment is on it (take the payment off first)'
    WHEN EXISTS (SELECT 1 FROM bank_invoice_links WHERE invoice_id = p_id) THEN 'a bank line is attached to it (take it off on the Bank page first)'
    WHEN EXISTS (SELECT 1 FROM partner_remittance_lines WHERE invoice_id = p_id) OR EXISTS (SELECT 1 FROM partner_remit_doc_lines WHERE invoice_id = p_id) THEN 'a partner''s remittance is tied to it'
    WHEN EXISTS (SELECT 1 FROM partner_submissions WHERE invoice_id = p_id) THEN 'it was sent to a partner'
    WHEN EXISTS (SELECT 1 FROM third_party_supplier_payments WHERE invoice_id = p_id OR goes_with_invoice_id = p_id) THEN 'a partner''s tank payment is tied to it'
    WHEN EXISTS (SELECT 1 FROM payment_plans WHERE invoice_id = p_id) THEN 'a payment plan is on it'
    WHEN EXISTS (SELECT 1 FROM project_billing_stages WHERE invoice_id = p_id) OR EXISTS (SELECT 1 FROM recurring_charge_runs WHERE invoice_id = p_id) THEN 'it is part of a billing schedule'
    WHEN EXISTS (SELECT 1 FROM tank_orders WHERE invoice_id = p_id AND credit_status = 'received') THEN 'the supplier''s credit for its tank already came back'
  END;
  SELECT count(*) INTO n_lines FROM invoice_lines WHERE invoice_id = p_id;
  SELECT count(*) INTO n_tank FROM tank_orders WHERE invoice_id = p_id AND purchase_order_id IS NOT NULL;
  IF p_dry THEN RETURN jsonb_build_object('ok', why IS NULL, 'why', why, 'st', v_st, 'lines', n_lines, 'tank', n_tank,
    'number', i.invoice_number, 'total', i.total, 'status', i.status); END IF;
  IF why IS NOT NULL THEN RAISE EXCEPTION 'It can not be deleted: %', why; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('invoices', p_id, 'delete', public.current_app_user_id(),
          to_jsonb(i) || jsonb_build_object('lines', (SELECT jsonb_agg(to_jsonb(l)) FROM invoice_lines l WHERE l.invoice_id = p_id)),
          jsonb_build_object('why', CASE WHEN v_st THEN 'Deleted from the customer''s page: from ServiceTitan, so kept hidden and marked Void' ELSE 'Deleted for good from the customer''s page' END));
  IF v_st THEN
    UPDATE invoices SET status = 'void', void_reason = coalesce(nullif(void_reason, ''), 'Deleted from the customer''s page'),
           app_edited_at = coalesce(app_edited_at, now()), deleted_at = now(), deleted_by = public.current_app_user_id() WHERE id = p_id;
    DELETE FROM supplier_invoice_customer_links WHERE invoice_id = p_id;
    RETURN jsonb_build_object('done', 'hidden', 'number', i.invoice_number);
  END IF;
  DELETE FROM supplier_invoice_customer_links WHERE invoice_id = p_id;
  DELETE FROM partner_statement_matches WHERE invoice_id = p_id;
  UPDATE partner_supplier_credits SET invoice_id = NULL WHERE invoice_id = p_id;
  DELETE FROM invoice_line_cost_skips WHERE invoice_id = p_id;
  DELETE FROM invoices WHERE id = p_id;
  RETURN jsonb_build_object('done', 'erased', 'number', i.invoice_number);
END $function$;
REVOKE EXECUTE ON FUNCTION public.invoice_delete(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invoice_delete(bigint, boolean) TO authenticated;

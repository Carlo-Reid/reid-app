-- The invoice reference number a supplier's credit prints (the invoice it takes back), read by the supplier's Rules ("Invoice reference number"),
-- is kept in supplier_invoices.original_order, which is what sinv_credit_original and sinv_credited match against (Carlo, Nov 25, 2026).
CREATE OR REPLACE FUNCTION public.supplier_invoice_ref_set(p_id bigint, p_ref text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v text := nullif(left(btrim(coalesce(p_ref, '')), 60), ''); v_old text;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  SELECT original_order INTO v_old FROM supplier_invoices WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That supplier invoice is not there'; END IF;
  UPDATE supplier_invoices SET original_order = v, updated_at = now() WHERE id = p_id AND original_order IS DISTINCT FROM v;
  IF FOUND THEN INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
    VALUES ('supplier_invoices', p_id, 'update', public.current_app_user_id(), jsonb_build_object('original_order', v_old), jsonb_build_object('original_order', v, 'why', 'Invoice reference number read by the supplier''s rules')); END IF;
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_ref_set(bigint, text) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.supplier_invoice_ref_set(bigint, text) TO authenticated;

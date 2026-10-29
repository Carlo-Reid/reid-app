-- Supplier payments: cancelled ones don't show any more; every payment (amount + date) for the owing amounts on the page.
CREATE OR REPLACE FUNCTION public.supplier_payments_list(p_supplier bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN NOT public._sup_pay_ok() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'amount', x.amount, 'paid_on', x.paid_on, 'method', x.method,
      'reference', x.reference, 'note', x.note, 'voided', false, 'at', x.created_at,
      'by', (SELECT public._emp_name(u.employee_id) FROM app_users u WHERE u.id = x.created_by)) ORDER BY x.paid_on DESC, x.id DESC)
    FROM (SELECT * FROM supplier_payments WHERE supplier_id = p_supplier AND voided_at IS NULL ORDER BY paid_on DESC, id DESC LIMIT 50) x), '[]'::jsonb) END $$;
CREATE OR REPLACE FUNCTION public.supplier_payments_all() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN NOT public._can_see_costs() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('supplier_id', supplier_id, 'amount', amount, 'paid_on', paid_on) ORDER BY paid_on)
    FROM supplier_payments WHERE voided_at IS NULL), '[]'::jsonb) END $$;
REVOKE EXECUTE ON FUNCTION public.supplier_payments_all() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_payments_all() TO authenticated;
NOTIFY pgrst, 'reload schema';

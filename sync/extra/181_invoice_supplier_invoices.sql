-- An invoice shows the supplier invoices attached to it (on Supplier invoices: "Customer invoice"); only for people who can see costs
CREATE OR REPLACE FUNCTION public.invoice_supplier_invoices(p_invoice bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._can_see_costs() THEN NULL ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'number', s.supplier_invoice_number, 'date', s.invoice_date,
      'total', s.total, 'supplier_id', s.supplier_id, 'supplier', btrim(sp.name), 'doc_type', s.doc_type) ORDER BY s.invoice_date, s.id)
    FROM supplier_invoice_customer_links k JOIN supplier_invoices s ON s.id = k.supplier_invoice_id JOIN suppliers sp ON sp.id = s.supplier_id WHERE k.invoice_id = p_invoice), '[]') END $f$;
REVOKE EXECUTE ON FUNCTION public.invoice_supplier_invoices(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invoice_supplier_invoices(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

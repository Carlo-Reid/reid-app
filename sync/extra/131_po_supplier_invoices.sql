-- The supplier invoices (and credits) matched to a PO, for the PO panel
CREATE OR REPLACE FUNCTION public.po_supplier_invoices(p_po bigint)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN NOT public._can_see_costs() THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', si.id, 'number', si.supplier_invoice_number, 'supplier', btrim(sp.name), 'date', si.invoice_date, 'total', si.total, 'type', si.doc_type,
             'by_hand', si.purchase_order_id IS NOT NULL, 'pages', (SELECT coalesce(jsonb_agg(d.id ORDER BY d.page_no), '[]') FROM supplier_doc_pages d WHERE d.supplier_invoice_id = si.id))
             ORDER BY si.invoice_date, si.id)
    FROM supplier_invoices si JOIN suppliers sp ON sp.id = si.supplier_id, purchase_orders po
    WHERE po.id = p_po
      AND (si.purchase_order_id = po.id OR (si.po_text IS NOT NULL AND si.po_text LIKE '%' || split_part(po.po_number, '-', 1) || '%'))
      AND public._sinv_po(si) = po.id), '[]') END
$function$;
REVOKE EXECUTE ON FUNCTION public.po_supplier_invoices(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.po_supplier_invoices(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

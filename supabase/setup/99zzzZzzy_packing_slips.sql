-- Supplier invoices: find the packing slips (the signed sheets that came with the equipment, scanned with the invoices).
-- Search by invoice, PO, job, who signed, or what was on it; each one opens its scanned pages.
CREATE OR REPLACE FUNCTION public.sinv_packing_slips(p_q text DEFAULT NULL, p_supplier bigint DEFAULT NULL, p_limit int DEFAULT 200)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE q text := nullif(btrim(coalesce(p_q, '')), '');
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  RETURN (
    SELECT coalesce(jsonb_agg(t.r ORDER BY t.n), '[]'::jsonb)
    FROM (SELECT row_number() OVER (ORDER BY i.invoice_date DESC NULLS LAST, i.id DESC) AS n,
                 jsonb_build_object('id', i.id, 'supplier_id', i.supplier_id, 'supplier', btrim(s.name), 'number', i.supplier_invoice_number, 'date', i.invoice_date,
                   'doc_type', i.doc_type, 'po_text', i.po_text, 'po_number', po.po_number, 'job_name', i.job_name, 'signed', i.handwriting,
                   'note', substring(i.read_notes FROM '[^.]{0,60}[Pp][Aa][Cc][Kk][Ii][Nn][Gg][ -][Ss][Ll][Ii][Pp][^.]{0,80}'),
                   'items', (SELECT string_agg(coalesce(x ->> 'description', x ->> 'code'), ' · ') FROM (SELECT x FROM jsonb_array_elements(i.lines) x LIMIT 4) y),
                   'pages', (SELECT count(*) FROM supplier_doc_pages d WHERE d.supplier_invoice_id = i.id)) AS r
          FROM supplier_invoices i JOIN suppliers s ON s.id = i.supplier_id LEFT JOIN purchase_orders po ON po.id = public._sinv_po(i)
          WHERE (i.read_notes ILIKE '%packing slip%' OR i.read_notes ILIKE '%packing-slip%')
            AND EXISTS (SELECT 1 FROM supplier_doc_pages d WHERE d.supplier_invoice_id = i.id)
            AND (p_supplier IS NULL OR i.supplier_id = p_supplier)
            AND (q IS NULL OR i.supplier_invoice_number ILIKE '%' || q || '%' OR i.po_text ILIKE '%' || q || '%' OR po.po_number ILIKE '%' || q || '%'
                 OR i.job_name ILIKE '%' || q || '%' OR i.handwriting ILIKE '%' || q || '%' OR i.read_notes ILIKE '%' || q || '%' OR i.lines::text ILIKE '%' || q || '%'
                 OR s.name ILIKE '%' || q || '%')
          ORDER BY i.invoice_date DESC NULLS LAST, i.id DESC LIMIT least(coalesce(p_limit, 200), 1000)) t);
END $function$;
REVOKE EXECUTE ON FUNCTION public.sinv_packing_slips(text, bigint, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sinv_packing_slips(text, bigint, int) TO authenticated;
NOTIFY pgrst, 'reload schema';

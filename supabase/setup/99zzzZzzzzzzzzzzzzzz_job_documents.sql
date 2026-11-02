-- Every document for the jobs behind some invoices: the invoices on those jobs, their POs, the supplier invoices
-- matched to those POs (with their page images), and the supplier files (packing slips, scans) tied to the POs
CREATE OR REPLACE FUNCTION public.job_documents(p_invoices bigint[])
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
DECLARE v_jobs bigint[]; v_pos bigint[]; v_bases text[]; cost boolean := public._can_see_costs();
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN NULL; END IF;
  SELECT array_agg(DISTINCT job_id) INTO v_jobs FROM invoices WHERE id = ANY (p_invoices[1:20]) AND job_id IS NOT NULL;
  SELECT array_agg(id), array_agg(DISTINCT split_part(po_number, '-', 1)) INTO v_pos, v_bases FROM purchase_orders WHERE job_id = ANY (coalesce(v_jobs, '{}'));
  RETURN jsonb_build_object(
    'jobs', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'number', j.job_number, 'type', t.name, 'customer', c.display_name, 'street', l.street, 'city', l.city,
               'person', (SELECT display_name FROM customers WHERE id = l.customer_id), 'person_id', l.customer_id)), '[]')
             FROM jobs j LEFT JOIN job_types t ON t.id = j.job_type_id LEFT JOIN customers c ON c.id = j.customer_id LEFT JOIN locations l ON l.id = j.location_id WHERE j.id = ANY (coalesce(v_jobs, '{}'))),
    'invoices', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.invoice_number, 'date', i.invoice_date, 'total', i.total, 'balance', i.balance_due, 'billed_to', c.display_name,
               'tank', EXISTS (SELECT 1 FROM third_party_supplier_payments x WHERE x.invoice_id = i.id)) ORDER BY i.invoice_date, i.id), '[]')
             FROM invoices i LEFT JOIN customers c ON c.id = i.customer_id
             WHERE (i.job_id = ANY (coalesce(v_jobs, '{}')) OR i.id = ANY (p_invoices[1:20])) AND i.status <> 'void'),
    'pos', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', po.id, 'number', po.po_number, 'supplier', btrim(s.name), 'date', coalesce(po.ordered_at, po.created_at)::date,
               'amount', CASE WHEN cost THEN po.amount END, 'status', po.status) ORDER BY po.po_number), '[]')
             FROM purchase_orders po JOIN suppliers s ON s.id = po.supplier_id WHERE po.id = ANY (coalesce(v_pos, '{}'))),
    'supplier_invoices', CASE WHEN cost THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', si.id, 'number', si.supplier_invoice_number, 'supplier', btrim(sp.name), 'date', si.invoice_date,
               'total', si.total, 'type', si.doc_type, 'po', si.po_text,
               'pages', (SELECT coalesce(jsonb_agg(d.id ORDER BY d.page_no), '[]') FROM supplier_doc_pages d WHERE d.supplier_invoice_id = si.id)) ORDER BY si.invoice_date, si.id), '[]')
             FROM supplier_invoices si JOIN suppliers sp ON sp.id = si.supplier_id
             WHERE (si.purchase_order_id = ANY (coalesce(v_pos, '{}')) OR (si.po_text IS NOT NULL AND EXISTS (SELECT 1 FROM unnest(coalesce(v_bases, '{}')) b WHERE length(b) >= 6 AND si.po_text LIKE '%' || b || '%')))
               AND public._sinv_po(si) = ANY (coalesce(v_pos, '{}'))) ELSE '[]'::jsonb END,
    'files', CASE WHEN cost THEN (SELECT coalesce(jsonb_agg(DISTINCT jsonb_build_object('id', m.id, 'file', m.file_name, 'mime', m.mime, 'received', m.received_at::date, 'supplier', m.supplier)), '[]')
             FROM supplier_mail_pos x JOIN supplier_mail m ON m.id = x.mail_id WHERE x.purchase_order_id = ANY (coalesce(v_pos, '{}'))) ELSE '[]'::jsonb END);
END $function$;
REVOKE EXECUTE ON FUNCTION public.job_documents(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.job_documents(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Find any number: invoices, proposals, jobs, visits, customers, plans, payments, POs, supplier invoices and statements,
-- supplier files (scans, quotes, emails) and equipment serials. Exact matches first, then numbers that start with it.
CREATE OR REPLACE FUNCTION public.find_number(p_q text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
DECLARE q text := btrim(coalesce(p_q, '')); k text; cost boolean := public._can_see_costs(); out jsonb := '[]';
BEGIN
  IF public.current_staff_role() IS NULL OR length(q) < 3 THEN RETURN '[]'; END IF;
  q := regexp_replace(q, '^#\s*', ''); k := upper(regexp_replace(q, '[^A-Za-z0-9]', '', 'g'));
  IF length(k) < 3 THEN RETURN '[]'; END IF;
  WITH hits AS (
    -- invoices (their number, PO, claim, authorization or partner account)
    SELECT 'invoice' AS kind, i.id, i.customer_id, 'Invoice ' || i.invoice_number AS label,
           CASE WHEN upper(i.invoice_number) = upper(q) OR i.invoice_number ILIKE q || '%' THEN '' WHEN upper(coalesce(i.po_number, '')) LIKE upper(q) || '%' THEN 'PO # on it: ' || i.po_number
                WHEN upper(coalesce(i.claim_number, '')) LIKE upper(q) || '%' THEN 'claim # ' || i.claim_number WHEN upper(coalesce(i.authorization_number, '')) LIKE upper(q) || '%' THEN 'approval # ' || i.authorization_number
                ELSE 'account # ' || i.partner_account END AS why,
           i.invoice_date AS d, i.total AS amount, (upper(i.invoice_number) = upper(q)) AS exact
    FROM invoices i WHERE i.invoice_number ILIKE q || '%' OR i.po_number ILIKE q || '%' OR i.claim_number ILIKE q || '%' OR i.authorization_number ILIKE q || '%' OR i.partner_account ILIKE q || '%'
    UNION ALL SELECT 'estimate', e.id, e.customer_id, 'Proposal ' || e.estimate_number, e.status, e.created_at::date, NULL, upper(e.estimate_number) = upper(q) FROM estimates e WHERE e.estimate_number ILIKE q || '%'
    UNION ALL SELECT 'job', j.id, j.customer_id, 'Job ' || j.job_number, (SELECT name FROM job_types WHERE id = j.job_type_id), j.created_at::date, NULL, upper(j.job_number) = upper(q) FROM jobs j WHERE j.job_number ILIKE q || '%'
    UNION ALL SELECT 'job', j.id, j.customer_id, 'Visit ' || v.visit_number, 'on job ' || j.job_number, v.scheduled_date, NULL, upper(v.visit_number::text) = upper(q) FROM visits v JOIN jobs j ON j.id = v.job_id WHERE v.visit_number::text ILIKE q || '%'
    UNION ALL SELECT 'customer', c.id, c.id, 'Customer ' || c.customer_number, NULL, c.created_at::date, NULL, upper(c.customer_number) = upper(q) FROM customers c WHERE c.customer_number ILIKE q || '%'
    UNION ALL SELECT 'customer', m.customer_id, m.customer_id, 'Plan ' || m.membership_number, (SELECT name FROM plan_types WHERE id = m.plan_type_id), m.start_date, NULL, upper(m.membership_number) = upper(q) FROM memberships m WHERE m.membership_number ILIKE q || '%'
    UNION ALL SELECT 'payment', (SELECT pa.invoice_id FROM payment_applications pa WHERE pa.payment_id = p.id ORDER BY pa.id LIMIT 1), p.customer_id, 'Payment ' || coalesce(p.payment_number, p.reference),
           CASE WHEN p.reference ILIKE q || '%' THEN 'reference ' || p.reference ELSE p.method END, p.received_on, p.amount, upper(coalesce(p.payment_number, '')) = upper(q) OR upper(coalesce(p.reference, '')) = upper(q)
      FROM payments p WHERE p.payment_number ILIKE q || '%' OR p.reference ILIKE q || '%'
    UNION ALL SELECT 'po', po.id, (SELECT customer_id FROM jobs WHERE id = po.job_id), 'PO ' || po.po_number, (SELECT btrim(name) FROM suppliers WHERE id = po.supplier_id) || CASE WHEN po.supplier_reference ILIKE q || '%' THEN ' · supplier # ' || po.supplier_reference ELSE '' END,
           po.created_at::date, po.amount, upper(po.po_number) = upper(q) OR upper(split_part(po.po_number, '-', 1)) = upper(q)
      FROM purchase_orders po WHERE po.po_number ILIKE q || '%' OR po.supplier_reference ILIKE q || '%'
    UNION ALL SELECT 'equipment', eq.id, l.customer_id, 'Serial ' || eq.serial_number, eq.model_number, eq.install_date, NULL, upper(eq.serial_number) = upper(q)
      FROM equipment eq JOIN locations l ON l.id = eq.location_id WHERE length(k) >= 4 AND eq.serial_number ILIKE q || '%'
    UNION ALL SELECT 'sinv', si.id, NULL, 'Supplier invoice ' || si.supplier_invoice_number, (SELECT btrim(name) FROM suppliers WHERE id = si.supplier_id) || CASE WHEN si.po_text ILIKE q || '%' THEN ' · PO on it: ' || si.po_text ELSE '' END,
           si.invoice_date, si.total, upper(si.supplier_invoice_number) = upper(q)
      FROM supplier_invoices si WHERE cost AND (si.supplier_invoice_number ILIKE q || '%' OR si.po_text ILIKE q || '%')
    UNION ALL SELECT 'sinv', sl.supplier_invoice_id, NULL, 'Statement line ' || sl.reference, (SELECT btrim(sp.name) FROM supplier_statements s JOIN suppliers sp ON sp.id = s.supplier_id WHERE s.id = sl.statement_id), sl.doc_date, sl.amount, upper(sl.reference) = upper(q)
      FROM supplier_statement_lines sl WHERE cost AND sl.supplier_invoice_id IS NULL AND sl.reference ILIKE q || '%'
    UNION ALL SELECT 'mail', sm.id, NULL, coalesce(nullif(sm.subject, ''), sm.file_name, 'Supplier file'), coalesce(sm.supplier, '') || CASE WHEN sm.file_name IS NOT NULL THEN ' · ' || sm.file_name ELSE '' END,
           sm.received_at::date, NULL, false
      FROM supplier_mail sm WHERE cost AND length(k) >= 5 AND (position(upper(q) IN upper(coalesce(sm.ocr_text, ''))) > 0 OR sm.file_name ILIKE '%' || q || '%' OR sm.subject ILIKE '%' || q || '%' OR (sm.result ->> 'ref') ILIKE '%' || q || '%')
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('kind', h.kind, 'id', h.id, 'customer_id', h.customer_id, 'customer', c.display_name, 'label', h.label, 'why', h.why, 'date', h.d, 'amount', h.amount, 'exact', h.exact)
         ORDER BY h.exact DESC, h.d DESC NULLS LAST), '[]') INTO out
  FROM (SELECT * FROM hits WHERE id IS NOT NULL ORDER BY exact DESC, d DESC NULLS LAST LIMIT 40) h LEFT JOIN customers c ON c.id = h.customer_id;
  RETURN out;
END $function$;
REVOKE EXECUTE ON FUNCTION public.find_number(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.find_number(text) TO authenticated;
CREATE INDEX IF NOT EXISTS invoices_number_pat ON public.invoices (invoice_number text_pattern_ops);
CREATE INDEX IF NOT EXISTS estimates_number_pat ON public.estimates (estimate_number text_pattern_ops);
CREATE INDEX IF NOT EXISTS jobs_number_pat ON public.jobs (job_number text_pattern_ops);
CREATE INDEX IF NOT EXISTS po_number_pat ON public.purchase_orders (po_number text_pattern_ops);
NOTIFY pgrst, 'reload schema';

-- Supplier invoices: which invoices were credited in full by a credit that names them (Carlo, Nov 24, 2026, Boone C333818).
-- P.O. 108624132-001 has two invoices (C333818 and C336872) and each has its own credit (C356199, C340833), so adding the two
-- invoices up against the P.O. said "over the P.O. by $1,746.00" while each invoice was right. The page uses this to leave an
-- invoice that was credited in full out of the sum of the other invoices on the same P.O.
-- Answer: { "<invoice id>": "<credit number>" }. Read only.
CREATE OR REPLACE FUNCTION public.sinv_credited(p_supplier bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN NOT (public._sinv_can_edit() OR public._can_see_costs()) THEN '{}'::jsonb ELSE
    coalesce((SELECT jsonb_object_agg(x.id::text, x.n) FROM (
      SELECT DISTINCT ON (i.id) i.id, c.supplier_invoice_number AS n
      FROM supplier_invoices c
      JOIN supplier_invoices i ON i.supplier_id = c.supplier_id AND i.doc_type = 'invoice' AND i.total > 0
       AND upper(regexp_replace(i.supplier_invoice_number, '[^A-Za-z0-9]', '', 'g')) = upper(regexp_replace(c.original_order, '[^A-Za-z0-9]', '', 'g'))
       AND abs(i.total + c.total) <= 1
      WHERE c.doc_type = 'credit' AND c.total < 0 AND coalesce(btrim(c.original_order), '') <> ''
        AND (p_supplier IS NULL OR c.supplier_id = p_supplier)
      ORDER BY i.id, c.invoice_date) x), '{}'::jsonb) END $function$;
REVOKE EXECUTE ON FUNCTION public.sinv_credited(bigint) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.sinv_credited(bigint) TO authenticated;

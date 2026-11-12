-- Supplier statement columns (Carlo, Nov 12, 2026): for a list of supplier invoices, in one call:
-- which customer invoices are attached, is it in our stock, is the paper itself a packing slip, and is its packing slip in the system.
CREATE OR REPLACE FUNCTION public.sinv_line_flags(p_ids bigint[])
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  RETURN (
    WITH sl AS MATERIALIZED (   -- every packing slip we hold a copy of, read once (a look-up for each line took 16 seconds)
      SELECT x.id, x.supplier_invoice_number AS num, public._sinv_po(x) AS po, nullif(btrim(x.po_text), '') AS pt,
             nullif(regexp_replace(upper(btrim(x.supplier_invoice_number)), '[.\-]0\d\d$', ''), '') AS nb
      FROM supplier_invoices x
      WHERE (x.read_notes ILIKE '%packing slip%' OR x.read_notes ILIKE '%packing-slip%')
        AND EXISTS (SELECT 1 FROM supplier_doc_pages d WHERE d.supplier_invoice_id = x.id)),
    me AS MATERIALIZED (
      SELECT i.id, public._sinv_po(i) AS po, nullif(btrim(i.po_text), '') AS pt,
             nullif(regexp_replace(upper(btrim(i.supplier_invoice_number)), '[.\-]0\d\d$', ''), '') AS nb,
             coalesce(i.read_notes ILIKE '%packing slip%' OR i.read_notes ILIKE '%packing-slip%', false) AS is_slip
      FROM supplier_invoices i WHERE i.id = ANY (coalesce(p_ids, '{}')))
    SELECT coalesce(jsonb_object_agg(m.id::text, jsonb_build_object(
      'cinv', (SELECT coalesce(jsonb_agg(c.invoice_number ORDER BY c.id), '[]'::jsonb) FROM supplier_invoice_customer_links k JOIN invoices c ON c.id = k.invoice_id WHERE k.supplier_invoice_id = m.id),
      'stock', EXISTS (SELECT 1 FROM supplier_invoice_stock s LEFT JOIN inventory_transactions t ON t.id = s.txn_id WHERE s.supplier_invoice_id = m.id AND (s.txn_id IS NULL OR t.undone_at IS NULL)),
      'is_slip', m.is_slip,
      'slip', (SELECT sl.num FROM sl WHERE sl.id <> m.id AND ((m.po IS NOT NULL AND sl.po = m.po) OR (m.pt IS NOT NULL AND sl.pt = m.pt) OR (m.nb IS NOT NULL AND sl.nb = m.nb)) ORDER BY sl.id LIMIT 1))), '{}'::jsonb)
    FROM me m);
END $function$;
REVOKE EXECUTE ON FUNCTION public.sinv_line_flags(bigint[]) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.sinv_line_flags(bigint[]) TO authenticated;

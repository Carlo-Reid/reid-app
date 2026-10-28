-- Supplier invoices "All suppliers · All statements" (about 2,200 invoices) timed out: finding each invoice's PO scanned every PO.
-- Plain indexes for the PO lookups, and the PO match done as two index lookups instead of one OR.
CREATE INDEX IF NOT EXISTS purchase_orders_po_number_all ON public.purchase_orders (po_number);
CREATE INDEX IF NOT EXISTS purchase_order_lines_po ON public.purchase_order_lines (purchase_order_id);
CREATE INDEX IF NOT EXISTS supplier_invoices_po_id ON public.supplier_invoices (purchase_order_id);
CREATE OR REPLACE FUNCTION public._sinv_po(p_inv supplier_invoices) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(p_inv.purchase_order_id,
    CASE WHEN p_inv.po_text ~ '^\s*[0-9][0-9-]{5,}\s*$' THEN
      (SELECT x.id FROM (
         SELECT po.id, po.supplier_id, true AS exact FROM purchase_orders po WHERE po.po_number = btrim(p_inv.po_text)
         UNION ALL
         SELECT po.id, po.supplier_id, false FROM purchase_orders po WHERE split_part(po.po_number, '-', 1) = btrim(p_inv.po_text)) x
       ORDER BY (x.supplier_id = p_inv.supplier_id) DESC, x.exact DESC, x.id LIMIT 1) END) $$;
ANALYZE public.purchase_orders; ANALYZE public.supplier_invoices; ANALYZE public.purchase_order_lines;
NOTIFY pgrst, 'reload schema';

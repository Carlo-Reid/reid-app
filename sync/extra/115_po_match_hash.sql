-- Supplier invoices: the PO box printed as "#93081855" (or "PO 93081855", "93081855 ") now matches PO 93081855.
-- A dash read into the number by mistake (779092-74 for 77909274) matches too.
-- Before, only a box that was nothing but the number was matched. The number is the first run of 6+ digits (dashes allowed).
CREATE OR REPLACE FUNCTION public._sinv_po(p_inv supplier_invoices) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(p_inv.purchase_order_id,
    (SELECT x.id FROM (SELECT rtrim(substring(coalesce(p_inv.po_text, '') FROM '[0-9][0-9-]{5,}'), '-') AS n) t
       CROSS JOIN LATERAL (
         SELECT po.id, po.supplier_id, true AS exact FROM purchase_orders po WHERE po.po_number = t.n
         UNION ALL
         SELECT po.id, po.supplier_id, false FROM purchase_orders po WHERE split_part(po.po_number, '-', 1) = t.n
         UNION ALL   -- a dash the reader added by mistake: 779092-74 is PO 77909274
         SELECT po.id, po.supplier_id, false FROM purchase_orders po WHERE t.n LIKE '%-%' AND po.po_number = replace(t.n, '-', '')) x
     WHERE t.n IS NOT NULL AND length(t.n) >= 6
     ORDER BY (x.supplier_id = p_inv.supplier_id) DESC, x.exact DESC, x.id LIMIT 1)) $$;
NOTIFY pgrst, 'reload schema';

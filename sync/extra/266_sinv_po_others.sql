-- A P.O. billed over two (or more) supplier invoices: the open invoice's page shows the other invoices' lines too (Carlo, Nov 12, 2026).
-- The other invoices on the same P.O. are found the same way supplier_invoices_list counts po_other_invoices.
CREATE OR REPLACE FUNCTION public.sinv_po_others(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE i supplier_invoices; v_po bigint; v_num text;
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  SELECT * INTO i FROM supplier_invoices WHERE id = p_id; IF i.id IS NULL THEN RETURN '[]'::jsonb; END IF;
  v_po := public._sinv_po(i); IF v_po IS NULL THEN RETURN '[]'::jsonb; END IF;
  SELECT po_number INTO v_num FROM purchase_orders WHERE id = v_po;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'number', o.supplier_invoice_number, 'date', o.invoice_date, 'subtotal', o.subtotal, 'total', o.total,
                   'lines', coalesce(o.lines, '[]'::jsonb)) ORDER BY o.invoice_date, o.id), '[]'::jsonb)
          FROM supplier_invoices o
          WHERE o.id <> i.id AND o.supplier_id = i.supplier_id AND o.total > 0
            AND (o.purchase_order_id = v_po OR btrim(o.po_text) = v_num OR btrim(o.po_text) = split_part(v_num, '-', 1)));
END $$;
GRANT EXECUTE ON FUNCTION public.sinv_po_others(bigint) TO authenticated;

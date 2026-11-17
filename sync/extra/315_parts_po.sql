-- A second P.O. on a job for the other parts, materials and supplies on its invoice (Carlo, Nov 17, 2026:
-- "have the ability to add all the items added to a second P.O. attached to the Job but do not make a credit note for this one").
-- It is a plain job P.O.: no tank order, no Credit Order. Which invoice lines went on which P.O. is kept here, so a line is not ordered twice.
-- No foreign keys to jobs / invoices on purpose (job_wipe and invoice_delete erase those rows themselves).
CREATE TABLE IF NOT EXISTS public.parts_po_lines (
  id bigserial PRIMARY KEY, invoice_id bigint NOT NULL, job_id bigint NOT NULL, invoice_line_id bigint NOT NULL,
  purchase_order_id bigint NOT NULL REFERENCES public.purchase_orders(id) ON DELETE CASCADE,
  created_by bigint, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS parts_po_lines_inv ON public.parts_po_lines (invoice_id);
CREATE INDEX IF NOT EXISTS parts_po_lines_line ON public.parts_po_lines (invoice_line_id);
ALTER TABLE public.parts_po_lines ENABLE ROW LEVEL SECURITY;

-- the lines that can still go on a parts P.O. (parts and materials from the price book; not the tank, not a line already on a P.O. that is not cancelled)
CREATE OR REPLACE FUNCTION public._parts_po_free(p_invoice bigint) RETURNS SETOF invoice_lines
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT l.* FROM invoice_lines l JOIN pricebook_items pi ON pi.id = l.item_id
  WHERE l.invoice_id = p_invoice AND l.kit_parent_line_id IS NULL AND l.quantity > 0 AND pi.item_type IN ('service', 'material')
    AND NOT EXISTS (SELECT 1 FROM tank_orders t WHERE t.invoice_line_id = l.id)
    AND NOT EXISTS (SELECT 1 FROM parts_po_lines p JOIN purchase_orders po ON po.id = p.purchase_order_id
                    WHERE p.invoice_line_id = l.id AND po.status::text <> 'cancelled')
  ORDER BY l.sequence, l.id $function$;

CREATE OR REPLACE FUNCTION public.parts_po_for(p_invoice bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i invoices; v_cost boolean := public._can_see_costs();
BEGIN
  SELECT * INTO i FROM invoices WHERE id = p_invoice; IF i.id IS NULL OR i.job_id IS NULL THEN RETURN NULL; END IF;
  IF NOT (public._can_invoice(i.job_id) OR public._tank_office()) THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('id', l.id, 'item_id', l.item_id, 'description', l.description, 'sku', pi.sku, 'quantity', l.quantity,
        'unit_cost', CASE WHEN v_cost THEN coalesce(l.unit_cost, pi.unit_cost) END) ORDER BY l.sequence, l.id)
      FROM public._parts_po_free(i.id) l LEFT JOIN pricebook_items pi ON pi.id = l.item_id), '[]'::jsonb),
    'orders', coalesce((SELECT jsonb_agg(jsonb_build_object('po_id', po.id, 'po_number', po.po_number, 'status', po.status, 'supplier', btrim(s.name), 'n', x.n,
        'amount', CASE WHEN v_cost THEN (SELECT round(sum(pl.quantity * pl.unit_cost), 2) FROM purchase_order_lines pl WHERE pl.purchase_order_id = po.id) END) ORDER BY po.id)
      FROM (SELECT purchase_order_id, count(*) AS n FROM parts_po_lines WHERE invoice_id = i.id GROUP BY 1) x
        JOIN purchase_orders po ON po.id = x.purchase_order_id LEFT JOIN suppliers s ON s.id = po.supplier_id), '[]'::jsonb));
END $function$;

CREATE OR REPLACE FUNCTION public.parts_po_make(p_invoice bigint, p_supplier bigint, p_supplier_name text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i invoices; v jsonb; v_po bigint; v_n int; v_me bigint := public.current_app_user_id();
BEGIN
  SELECT * INTO i FROM invoices WHERE id = p_invoice; IF i.id IS NULL THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
  IF i.job_id IS NULL THEN RAISE EXCEPTION 'This invoice has no job, so I can not make a P.O. for it'; END IF;
  IF NOT (public._can_invoice(i.job_id) OR public._tank_office()) THEN RAISE EXCEPTION 'You can only do this on the jobs you are on'; END IF;
  IF p_supplier IS NULL AND nullif(btrim(coalesce(p_supplier_name, '')), '') IS NULL THEN RAISE EXCEPTION 'Pick the supplier first'; END IF;
  SELECT count(*) INTO v_n FROM public._parts_po_free(i.id);
  IF v_n = 0 THEN RAISE EXCEPTION 'There are no parts or materials on this invoice that still need a P.O.'; END IF;
  v := public.get_po_number(i.job_id, p_supplier, p_supplier_name, 'Parts and materials for the job');
  v_po := (v ->> 'id')::bigint;
  INSERT INTO purchase_order_lines (purchase_order_id, item_id, description, quantity, unit_cost, quantity_received, job_id)
  SELECT v_po, l.item_id, left(coalesce(l.description, 'Part'), 500), l.quantity, coalesce(l.unit_cost, pi.unit_cost, 0), 0, i.job_id
  FROM public._parts_po_free(i.id) l LEFT JOIN pricebook_items pi ON pi.id = l.item_id;
  INSERT INTO parts_po_lines (invoice_id, job_id, invoice_line_id, purchase_order_id, created_by)
  SELECT i.id, i.job_id, l.id, v_po, v_me FROM public._parts_po_free(i.id) l;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('purchase_orders', v_po, 'insert', v_me, jsonb_build_object('invoice', i.invoice_number, 'po', v ->> 'po_number', 'parts_po', true, 'lines', v_n));
  RETURN jsonb_build_object('po_id', v_po, 'po_number', v ->> 'po_number', 'supplier', v ->> 'supplier', 'lines', v_n);
END $function$;

REVOKE EXECUTE ON FUNCTION public._parts_po_free(bigint), public.parts_po_for(bigint), public.parts_po_make(bigint, bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.parts_po_for(bigint), public.parts_po_make(bigint, bigint, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Supplier invoices: "Read it again" (Carlo, Nov 10, 2026). The app reads the invoice's saved pages again in the browser and,
-- after a yes, its lines are replaced with the new reading. Lines typed in by hand are kept. The old lines go in the audit log.
-- p_extra.po_text: the PO number read off the page. It is kept only when the invoice has no PO yet, and matched when that PO is in the app.
DROP FUNCTION IF EXISTS public.supplier_invoice_reread(bigint, jsonb);
CREATE OR REPLACE FUNCTION public.supplier_invoice_reread(p_id bigint, p_lines jsonb, p_extra jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE i supplier_invoices; v_old jsonb; v_hand jsonb; v_pot text := nullif(btrim(coalesce(p_extra ->> 'po_text', '')), ''); v_po bigint;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN RAISE EXCEPTION 'No lines were read, so nothing was changed'; END IF;
  SELECT * INTO i FROM supplier_invoices WHERE id = p_id;
  IF i.id IS NULL THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
  v_old := coalesce(i.lines, '[]'::jsonb);
  SELECT coalesce(jsonb_agg(x), '[]'::jsonb) INTO v_hand FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_old) = 'array' THEN v_old ELSE '[]'::jsonb END) x WHERE coalesce((x ->> 'by_hand')::boolean, false);
  IF i.purchase_order_id IS NULL AND v_pot IS NOT NULL THEN
    SELECT id INTO v_po FROM purchase_orders WHERE po_number = v_pot OR split_part(po_number, '-', 1) = v_pot
      ORDER BY (supplier_id IS NOT DISTINCT FROM i.supplier_id) DESC, (po_number = v_pot) DESC, id LIMIT 1;
  END IF;
  UPDATE supplier_invoices SET lines = p_lines || v_hand,
    po_text = coalesce(nullif(btrim(po_text), ''), v_pot),
    purchase_order_id = coalesce(purchase_order_id, v_po),
    read_notes = concat_ws(' · ', nullif(read_notes, ''), 'Read again in the app on ' || to_char(now() AT TIME ZONE 'America/Toronto', 'Mon FMDD, YYYY')), updated_at = now()
  WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoices', p_id, 'update', public.current_app_user_id(), jsonb_build_object('read_again', true, 'lines_before', v_old, 'lines_after', p_lines, 'po_text', v_pot, 'po_matched', v_po));
END $$;
REVOKE ALL ON FUNCTION public.supplier_invoice_reread(bigint, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_reread(bigint, jsonb, jsonb) TO authenticated;

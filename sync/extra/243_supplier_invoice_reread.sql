-- Supplier invoices: "Read it again" (Carlo, Nov 10, 2026). The app reads the invoice's saved pages again in the browser and,
-- after a yes, its lines are replaced with the new reading. Lines typed in by hand are kept. The old lines go in the audit log.
CREATE OR REPLACE FUNCTION public.supplier_invoice_reread(p_id bigint, p_lines jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_old jsonb; v_hand jsonb;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN RAISE EXCEPTION 'No lines were read, so nothing was changed'; END IF;
  SELECT coalesce(lines, '[]'::jsonb) INTO v_old FROM supplier_invoices WHERE id = p_id;
  IF v_old IS NULL THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
  SELECT coalesce(jsonb_agg(x), '[]'::jsonb) INTO v_hand FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_old) = 'array' THEN v_old ELSE '[]'::jsonb END) x WHERE coalesce((x ->> 'by_hand')::boolean, false);
  UPDATE supplier_invoices SET lines = p_lines || v_hand,
    read_notes = concat_ws(' · ', nullif(read_notes, ''), 'Read again in the app on ' || to_char(now() AT TIME ZONE 'America/Toronto', 'Mon FMDD, YYYY')), updated_at = now()
  WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoices', p_id, 'update', public.current_app_user_id(), jsonb_build_object('read_again', true, 'lines_before', v_old, 'lines_after', p_lines));
END $$;
REVOKE ALL ON FUNCTION public.supplier_invoice_reread(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_reread(bigint, jsonb) TO authenticated;

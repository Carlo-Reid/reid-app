-- Add a supplier from the app (e.g. while dropping in invoices from a supplier we haven't used before)
CREATE OR REPLACE FUNCTION public.supplier_create(p_name text, p_phone text DEFAULT NULL)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_id bigint; n text := btrim(coalesce(p_name, ''));
BEGIN
  IF NOT (public.has_permission('pricebook.edit') OR public._sinv_can_edit() OR public.current_staff_role() = 'owner') THEN RAISE EXCEPTION 'You need "Edit the price book" to add a supplier'; END IF;
  IF length(n) < 2 THEN RAISE EXCEPTION 'Type the supplier''s name'; END IF;
  SELECT id INTO v_id FROM suppliers WHERE lower(btrim(name)) = lower(n) OR lower(split_part(btrim(name), ' ', 1)) = lower(n) ORDER BY id LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;   -- already there
  INSERT INTO suppliers (name, phone) VALUES (n, nullif(btrim(coalesce(p_phone, '')), '')) RETURNING id INTO v_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('suppliers', v_id, 'insert', public.current_app_user_id(), jsonb_build_object('name', n, 'phone', p_phone));
  RETURN v_id;
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_create(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_create(text, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Delete a piece of equipment that was entered by mistake (customer page, Section 3). Needs equipment.edit.
-- Its warranties go with it; anything else pointing at it is cleared (optional links emptied, child rows removed).
CREATE OR REPLACE FUNCTION public.equipment_delete(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE q equipment; r record;
BEGIN
  IF NOT public.has_permission('equipment.edit') THEN RAISE EXCEPTION 'You don''t have permission to edit equipment'; END IF;
  SELECT * INTO q FROM equipment WHERE id = p_id; IF q.id IS NULL THEN RAISE EXCEPTION 'That equipment is already gone'; END IF;
  BEGIN
    FOR r IN SELECT c.conrelid::regclass AS tbl, a.attname AS col, a.attnotnull AS nn FROM pg_constraint c
             JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
             WHERE c.contype = 'f' AND c.confrelid = 'public.equipment'::regclass LOOP
      IF r.nn THEN EXECUTE format('DELETE FROM %s WHERE %I = $1', r.tbl, r.col) USING p_id;
      ELSE EXECUTE format('UPDATE %s SET %I = NULL WHERE %I = $1', r.tbl, r.col, r.col) USING p_id; END IF;
    END LOOP;
    DELETE FROM equipment WHERE id = p_id;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'This equipment is linked to something that has to stay (%), so it can''t be deleted. Mark it Removed instead.', SQLERRM;
  END;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('equipment', p_id, 'delete', public.current_app_user_id(),
    jsonb_build_object('location', q.location_id, 'model', q.model_number, 'serial', q.serial_number, 'st_id', q.st_id));
END $function$;
REVOKE EXECUTE ON FUNCTION public.equipment_delete(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.equipment_delete(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- Two suppliers that are the same one: move everything from one (p_from) onto the other (p_into), then remove p_from.
-- Every table with a supplier_id column moves over. Where the one kept already has the same thing (a logo, a price for
-- the same item) the copy is dropped; the same supplier invoice # on both stops the merge (nothing changes).
-- Then: Breezehill Heating (made by hand on Nov 5) goes into Breezehill Heating LTD (from ServiceTitan, with its POs).
-- Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public._supplier_merge(p_from bigint, p_into bigint) RETURNS text LANGUAGE plpgsql SET search_path TO 'public' AS $f$
DECLARE t record; n int; v_moved text := ''; f suppliers; i suppliers;
BEGIN
  SELECT * INTO f FROM suppliers WHERE id = p_from; SELECT * INTO i FROM suppliers WHERE id = p_into;
  IF f.id IS NULL OR i.id IS NULL OR p_from = p_into THEN RETURN 'nothing to merge'; END IF;
  IF EXISTS (SELECT 1 FROM supplier_invoices a JOIN supplier_invoices b ON b.supplier_invoice_number = a.supplier_invoice_number WHERE a.supplier_id = p_from AND b.supplier_id = p_into) THEN
    RAISE EXCEPTION 'Both have the same supplier invoice number: merge those by hand first'; END IF;
  DELETE FROM supplier_logos WHERE supplier_id = p_from AND EXISTS (SELECT 1 FROM supplier_logos WHERE supplier_id = p_into);
  DELETE FROM supplier_items x WHERE x.supplier_id = p_from AND EXISTS (SELECT 1 FROM supplier_items y WHERE y.supplier_id = p_into AND y.item_id = x.item_id);
  DELETE FROM supplier_statements x WHERE x.supplier_id = p_from AND NOT EXISTS (SELECT 1 FROM supplier_statement_lines l WHERE l.statement_id = x.id)
    AND EXISTS (SELECT 1 FROM supplier_statements y WHERE y.supplier_id = p_into AND y.statement_date = x.statement_date AND y.account IS NOT DISTINCT FROM x.account);
  FOR t IN SELECT c.table_name FROM information_schema.columns c JOIN information_schema.tables tb ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name AND tb.table_type = 'BASE TABLE'
           WHERE c.table_schema = 'public' AND c.column_name = 'supplier_id' AND c.data_type = 'bigint' ORDER BY 1 LOOP
    EXECUTE format('UPDATE %I SET supplier_id = $1 WHERE supplier_id = $2', t.table_name) USING p_into, p_from; GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN v_moved := v_moved || t.table_name || ' ' || n || '; '; END IF;
  END LOOP;
  UPDATE suppliers SET phone = coalesce(phone, f.phone), email = coalesce(email, f.email), street = coalesce(street, f.street), city = coalesce(city, f.city),
         province = coalesce(province, f.province), postal_code = coalesce(postal_code, f.postal_code), account_number = coalesce(account_number, f.account_number),
         payment_terms_days = coalesce(payment_terms_days, f.payment_terms_days), notes = coalesce(notes, f.notes), updated_at = now() WHERE id = p_into;
  DELETE FROM suppliers WHERE id = p_from;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('suppliers', p_into, 'update', NULL, jsonb_build_object('merged_in', f.name, 'merged_id', p_from, 'moved', v_moved));
  RETURN v_moved;
END $f$;
REVOKE EXECUTE ON FUNCTION public._supplier_merge(bigint, bigint) FROM PUBLIC, anon, authenticated;

SELECT public._supplier_merge(62, 54) WHERE EXISTS (SELECT 1 FROM suppliers WHERE id = 62 AND name ~* '^breezehill')
                                        AND EXISTS (SELECT 1 FROM suppliers WHERE id = 54 AND name ~* '^breezehill');
NOTIFY pgrst, 'reload schema';

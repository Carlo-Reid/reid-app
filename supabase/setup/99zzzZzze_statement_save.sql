-- Supplier invoices: load a supplier's monthly statement from the app (read from the PDF in the browser, checked by a person).
-- Saves the statement (supplier + date + account) with its lines, links each line to the invoice with the same number,
-- and keeps a record of what it replaced.
CREATE OR REPLACE FUNCTION public.supplier_statement_save(p jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_sup bigint := (p ->> 'supplier_id')::bigint; v_date date := (p ->> 'statement_date')::date; v_acct text := coalesce(p ->> 'account', '');
  v_st bigint; v_old jsonb; x jsonb; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to load statements'; END IF;
  IF v_sup IS NULL OR v_date IS NULL THEN RAISE EXCEPTION 'Pick the supplier and the statement date'; END IF;
  IF jsonb_typeof(p -> 'lines') <> 'array' OR jsonb_array_length(p -> 'lines') = 0 THEN RAISE EXCEPTION 'No lines to save'; END IF;
  SELECT id, jsonb_build_object('total', total, 'aging', aging, 'lines', (SELECT count(*) FROM supplier_statement_lines l WHERE l.statement_id = s.id))
    INTO v_st, v_old FROM supplier_statements s WHERE supplier_id = v_sup AND statement_date = v_date AND account = v_acct;
  IF v_st IS NULL THEN
    INSERT INTO supplier_statements (supplier_id, statement_date, account, total, aging, file_name, pages, created_by)
    VALUES (v_sup, v_date, v_acct, (p ->> 'total')::numeric, p -> 'aging', p ->> 'file_name', (p ->> 'pages')::int, v_me) RETURNING id INTO v_st;
  ELSE
    UPDATE supplier_statements SET total = (p ->> 'total')::numeric, aging = coalesce(p -> 'aging', aging), file_name = coalesce(p ->> 'file_name', file_name), pages = coalesce((p ->> 'pages')::int, pages) WHERE id = v_st;
    DELETE FROM supplier_statement_lines WHERE statement_id = v_st;
  END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(p -> 'lines') LOOP
    INSERT INTO supplier_statement_lines (statement_id, reference, doc_date, code, amount, branch, supplier_invoice_id)
    VALUES (v_st, btrim(x ->> 'reference'), (x ->> 'date')::date, nullif(x ->> 'code', ''), (x ->> 'amount')::numeric, nullif(x ->> 'branch', ''),
            (SELECT id FROM supplier_invoices i WHERE i.supplier_id = v_sup AND i.supplier_invoice_number = btrim(x ->> 'reference') LIMIT 1))
    ON CONFLICT (statement_id, reference) DO UPDATE SET amount = EXCLUDED.amount, doc_date = EXCLUDED.doc_date, code = EXCLUDED.code, branch = EXCLUDED.branch;
  END LOOP;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('supplier_statements', v_st, CASE WHEN v_old IS NULL THEN 'insert' ELSE 'update' END, v_me, v_old,
          jsonb_build_object('total', p ->> 'total', 'lines', jsonb_array_length(p -> 'lines'), 'file', p ->> 'file_name', 'loaded_in_app', true));
  RETURN v_st;
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_statement_save(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_statement_save(jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';

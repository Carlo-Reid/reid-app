-- =====================================================================
-- A supplier statement: Accept it (we checked it and agree: who and when), and Add the missing invoices
-- (each invoice or credit line on it that isn't in the app yet becomes a supplier invoice: number, date, amount,
-- tied to its line, so it can be matched to its PO and paid; its copy can be dropped in later).
-- Same people who load supplier invoices. Safe to run more than once.
-- =====================================================================
ALTER TABLE public.supplier_statements ADD COLUMN IF NOT EXISTS accepted_at timestamptz, ADD COLUMN IF NOT EXISTS accepted_by bigint;

CREATE OR REPLACE FUNCTION public.supplier_statement_accept(p_id bigint, p_on boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE s supplier_statements;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier statements'; END IF;
  UPDATE supplier_statements SET accepted_at = CASE WHEN p_on THEN now() END, accepted_by = CASE WHEN p_on THEN public.current_app_user_id() END
  WHERE id = p_id RETURNING * INTO s;
  IF s.id IS NULL THEN RAISE EXCEPTION 'That statement is gone'; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_statements', p_id, 'update', public.current_app_user_id(), jsonb_build_object(CASE WHEN p_on THEN 'accepted' ELSE 'accept_undone' END, s.statement_date, 'total', s.total));
  RETURN jsonb_build_object('at', s.accepted_at, 'by', public._staff_name(s.accepted_by));
END $f$;

-- which of these statements were accepted, by whom and when
CREATE OR REPLACE FUNCTION public.supplier_statement_accepts(p_ids bigint[]) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '{}'::jsonb ELSE coalesce((SELECT jsonb_object_agg(s.id, jsonb_build_object('at', s.accepted_at, 'by', public._staff_name(s.accepted_by)))
    FROM supplier_statements s WHERE s.id = ANY (p_ids[1:500]) AND s.accepted_at IS NOT NULL), '{}') END $f$;

-- the lines on the statement with no supplier invoice in the app: add each one, and tie the line to it
CREATE OR REPLACE FUNCTION public.supplier_statement_add_missing(p_id bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE s supplier_statements; l record; v_id bigint; n int := 0;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to load supplier invoices'; END IF;
  SELECT * INTO s FROM supplier_statements WHERE id = p_id; IF s.id IS NULL THEN RAISE EXCEPTION 'That statement is gone'; END IF;
  FOR l IN SELECT * FROM supplier_statement_lines WHERE statement_id = p_id AND coalesce(code, 'I') IN ('I', 'C', 'D', 'S') ORDER BY doc_date, id LOOP
    SELECT id INTO v_id FROM supplier_invoices WHERE supplier_id = s.supplier_id AND supplier_invoice_number = l.reference;
    IF v_id IS NULL THEN
      INSERT INTO supplier_invoices (supplier_id, supplier_invoice_number, invoice_date, total, doc_type, lines, read_notes)
      VALUES (s.supplier_id, l.reference, l.doc_date, l.amount, CASE WHEN l.amount < 0 OR l.code = 'C' THEN 'credit' ELSE 'invoice' END, '[]',
              'Added from the ' || to_char(s.statement_date, 'Mon DD, YYYY') || ' statement (no copy of the invoice yet).')
      RETURNING id INTO v_id;
      INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
      VALUES ('supplier_invoices', v_id, 'insert', public.current_app_user_id(), jsonb_build_object('from_statement', s.statement_date, 'number', l.reference, 'total', l.amount));
      n := n + 1;
    END IF;
    -- every statement line with this number (this statement and others) points at it
    UPDATE supplier_statement_lines x SET supplier_invoice_id = v_id FROM supplier_statements y
      WHERE y.id = x.statement_id AND y.supplier_id = s.supplier_id AND x.reference = l.reference AND x.supplier_invoice_id IS NULL;
  END LOOP;
  RETURN n;
END $f$;

REVOKE EXECUTE ON FUNCTION public.supplier_statement_accept(bigint, boolean), public.supplier_statement_accepts(bigint[]), public.supplier_statement_add_missing(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_statement_accept(bigint, boolean), public.supplier_statement_accepts(bigint[]), public.supplier_statement_add_missing(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

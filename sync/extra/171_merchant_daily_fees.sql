-- Card statements: the fees come out of the bank every day (the statement's "Daily Fee Activity"), not once a month:
-- each day's fee is tied to its fee line in the bank (same amount, that day or a few days after) and the line gets a note.
ALTER TABLE public.merchant_statements ADD COLUMN IF NOT EXISTS fees jsonb;
CREATE TABLE IF NOT EXISTS public.merchant_fee_lines (
  statement_id bigint NOT NULL REFERENCES public.merchant_statements(id) ON DELETE CASCADE, fee_date date NOT NULL, amount numeric(12,2) NOT NULL,
  bank_id bigint REFERENCES public.bank_transactions(id) ON DELETE SET NULL, PRIMARY KEY (statement_id, fee_date, amount));
ALTER TABLE public.merchant_fee_lines ENABLE ROW LEVEL SECURITY; REVOKE ALL ON public.merchant_fee_lines FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.merchant_fees_match(p_id bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE st merchant_statements; x jsonb; hit bigint; n int := 0; nf int := 0;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  SELECT * INTO st FROM merchant_statements WHERE id = p_id; IF st.id IS NULL OR st.fees IS NULL THEN RETURN jsonb_build_object('fees', 0, 'fees_found', 0); END IF;
  DELETE FROM merchant_fee_lines WHERE statement_id = p_id;
  FOR x IN SELECT * FROM jsonb_array_elements(st.fees) ORDER BY (value ->> 'date') LOOP
    IF coalesce((x ->> 'amount')::numeric, 0) <= 0 THEN CONTINUE; END IF; n := n + 1;
    SELECT t.id INTO hit FROM bank_transactions t
      WHERE t.amount_out = (x ->> 'amount')::numeric AND t.txn_date BETWEEN (x ->> 'date')::date AND (x ->> 'date')::date + 5 AND t.description ~* 'ELAVON|MRCH|CMS/GES|MERCH'
        AND NOT EXISTS (SELECT 1 FROM merchant_fee_lines f WHERE f.bank_id = t.id)
      ORDER BY t.txn_date, t.id LIMIT 1;
    INSERT INTO merchant_fee_lines (statement_id, fee_date, amount, bank_id) VALUES (p_id, (x ->> 'date')::date, (x ->> 'amount')::numeric, hit) ON CONFLICT DO NOTHING;
    IF hit IS NOT NULL THEN nf := nf + 1;
      UPDATE bank_transactions SET note = 'Card fees for ' || to_char((x ->> 'date')::date, 'Mon FMDD, YYYY') || ' (Elavon merchant …' || right(st.merchant_no, 4) || ', ' || to_char(st.statement_date, 'FMMonth YYYY') || ' statement)'
        WHERE id = hit AND (note IS NULL OR note LIKE 'Card fees for %' OR note LIKE 'Card processing fees%');
    END IF;
  END LOOP;
  RETURN jsonb_build_object('fees', n, 'fees_found', nf);
END $f$;
REVOKE EXECUTE ON FUNCTION public.merchant_fees_match(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.merchant_fees_match(bigint) TO authenticated;

DO $do$
DECLARE s1 text := pg_get_functiondef('public.merchant_statement_save(jsonb)'::regprocedure);
        s2 text := pg_get_functiondef('public.merchant_statements_list()'::regprocedure);
BEGIN
  IF s1 NOT LIKE '%merchant_fees_match%' THEN
    s1 := replace(s1, $a$INSERT INTO merchant_statements (processor, merchant_no, statement_date, total_sales, total_fees, fee_account, file_name, pdf, loaded_by)$a$,
                      $a$INSERT INTO merchant_statements (processor, merchant_no, statement_date, total_sales, total_fees, fee_account, file_name, pdf, loaded_by, fees)$a$);
    s1 := replace(s1, $a$p ->> 'file_name', p ->> 'pdf', public.current_app_user_id())$a$, $a$p ->> 'file_name', p ->> 'pdf', public.current_app_user_id(), p -> 'fees')$a$);
    s1 := replace(s1, $a$RETURN jsonb_build_object('id', v) || public.merchant_statement_match(v);$a$, $a$RETURN jsonb_build_object('id', v) || public.merchant_statement_match(v) || public.merchant_fees_match(v);$a$);
    IF s1 NOT LIKE '%merchant_fees_match%' OR s1 NOT LIKE '%p -> ''fees'')%' THEN RAISE EXCEPTION 'merchant_statement_save: anchors not found'; END IF; EXECUTE s1; END IF;
  IF s2 NOT LIKE '%merchant_fee_lines%' THEN
    s2 := replace(s2, $a$'fees', s.total_fees,$a$, $a$'fees', s.total_fees, 'fee_days', (SELECT count(*) FROM merchant_fee_lines f WHERE f.statement_id = s.id), 'fee_found', (SELECT count(*) FROM merchant_fee_lines f WHERE f.statement_id = s.id AND f.bank_id IS NOT NULL),$a$);
    IF s2 NOT LIKE '%merchant_fee_lines%' THEN RAISE EXCEPTION 'merchant_statements_list: anchor not found'; END IF; EXECUTE s2; END IF;
END $do$;
NOTIFY pgrst, 'reload schema';

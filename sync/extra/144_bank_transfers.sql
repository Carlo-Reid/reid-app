-- Bank: transfers between the main account and Savings, paired up (Savings out = Main in, and the other way), shown in the ledger
CREATE TABLE IF NOT EXISTS public.bank_transfer_links (
  a_id bigint NOT NULL REFERENCES public.bank_transactions(id) ON DELETE CASCADE,
  b_id bigint NOT NULL REFERENCES public.bank_transactions(id) ON DELETE CASCADE,
  amount numeric(14,2), made_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (a_id), UNIQUE (b_id));
ALTER TABLE public.bank_transfer_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.bank_transfer_links FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.bank_transfer_match() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE m record; hit bigint; n int := 0;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  DELETE FROM bank_transfer_links;
  FOR m IN SELECT * FROM bank_transactions WHERE account = 'main' AND description ~* '^TF\s' AND (amount_in > 0 OR amount_out > 0) ORDER BY txn_date, id LOOP
    SELECT s.id INTO hit FROM bank_transactions s
      WHERE s.account = 'savings' AND s.txn_date BETWEEN m.txn_date - 3 AND m.txn_date + 3
        AND ((m.amount_in > 0 AND s.amount_out = m.amount_in) OR (m.amount_out > 0 AND s.amount_in = m.amount_out))
        AND NOT EXISTS (SELECT 1 FROM bank_transfer_links t WHERE t.b_id = s.id)
      ORDER BY abs(s.txn_date - m.txn_date), (s.description ~* '^TF\s') DESC, s.id LIMIT 1;
    IF hit IS NOT NULL THEN INSERT INTO bank_transfer_links (a_id, b_id, amount) VALUES (m.id, hit, greatest(m.amount_in, m.amount_out)); n := n + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('paired', n);
END $f$;
REVOKE EXECUTE ON FUNCTION public.bank_transfer_match() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bank_transfer_match() TO authenticated;

CREATE OR REPLACE FUNCTION public._bank_xfer(p_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT jsonb_build_object('id', o.id, 'account', o.account, 'date', o.txn_date, 'amount', t.amount, 'to', o.amount_in > 0)
  FROM bank_transfer_links t JOIN bank_transactions o ON o.id = CASE WHEN t.a_id = p_id THEN t.b_id ELSE t.a_id END
  WHERE t.a_id = p_id OR t.b_id = p_id LIMIT 1 $f$;
REVOKE EXECUTE ON FUNCTION public._bank_xfer(bigint) FROM PUBLIC, anon;

DO $do$
DECLARE s1 text := pg_get_functiondef('public.bank_list(text, date, date, text, text, int, int, text)'::regprocedure);
        s2 text := pg_get_functiondef('public.bank_ledger(text, text, date, date, boolean, int, int)'::regprocedure);
BEGIN
  IF s1 NOT LIKE '%_bank_xfer%' THEN
    s1 := replace(s1, $a$'cat', cat, 'note', note,$a$, $a$'cat', cat, 'note', note, 'transfer', public._bank_xfer(x.id),$a$);
    IF s1 NOT LIKE '%_bank_xfer%' THEN RAISE EXCEPTION 'bank_list: anchor not found'; END IF; EXECUTE s1; END IF;
  IF s2 NOT LIKE '%_bank_xfer%' THEN
    s2 := replace(s2, $a$'note', x.note,$a$, $a$'note', x.note, 'transfer', public._bank_xfer(x.id),$a$);
    s2 := replace(s2, $a$OR EXISTS (SELECT 1 FROM bank_invoice_links k WHERE k.bank_id = b.id))$a$,
                      $a$OR EXISTS (SELECT 1 FROM bank_invoice_links k WHERE k.bank_id = b.id) OR EXISTS (SELECT 1 FROM bank_transfer_links t WHERE b.id IN (t.a_id, t.b_id)))$a$);
    IF s2 NOT LIKE '%_bank_xfer%' OR s2 NOT LIKE '%bank_transfer_links%' THEN RAISE EXCEPTION 'bank_ledger: anchor not found'; END IF; EXECUTE s2; END IF;
END $do$;
NOTIFY pgrst, 'reload schema';

-- Bank: match the money customers paid us directly to the payments in the app (and so to their invoices):
--   card      = Elavon / merchant / Amex / online deposits  <->  card payments (each card payment lands on its own, a day or few later)
--   etransfer = Interac e-Transfers received (either account) <->  e-Transfer payments
--   cheque    = branch / mobile / manual deposits            <->  cheques (a deposit is often several cheques)
--   financing = Financeit and other lender deposits          <->  financing payments
-- One year at a time (quicker). Ties made by hand are kept.
CREATE OR REPLACE FUNCTION public.bank_pay_match(p_kind text, p_year int) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off' SET statement_timeout TO '120s' AS $f$
DECLARE d record; g record; v_from date := make_date(p_year, 1, 1); v_to date := make_date(p_year, 12, 31); back int; fwd int; n1 int := 0; n2 int := 0; n3 int := 0; nd int := 0;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  IF p_kind NOT IN ('card', 'etransfer', 'cheque', 'financing') THEN RAISE EXCEPTION 'Unknown kind %', p_kind; END IF;
  -- how far the deposit can come after (and before) the payment's date
  back := CASE p_kind WHEN 'card' THEN 1 WHEN 'etransfer' THEN 4 WHEN 'cheque' THEN 3 ELSE 5 END;
  fwd  := CASE p_kind WHEN 'card' THEN 7 WHEN 'etransfer' THEN 6 WHEN 'cheque' THEN 21 ELSE 30 END;
  CREATE TEMP TABLE IF NOT EXISTS _pd (id bigint PRIMARY KEY, dt date, amt numeric, done text) ON COMMIT DROP; TRUNCATE _pd;
  CREATE TEMP TABLE IF NOT EXISTS _pp (id bigint PRIMARY KEY, dt date, amt numeric, bank bigint) ON COMMIT DROP; TRUNCATE _pp;
  -- the deposits (not tied to anything yet)
  INSERT INTO _pd SELECT b.id, b.txn_date, b.amount_in, NULL FROM bank_transactions b
    WHERE b.amount_in > 0 AND b.txn_date BETWEEN v_from AND v_to + 30
      AND NOT EXISTS (SELECT 1 FROM bank_invoice_links k WHERE k.bank_id = b.id AND (k.how IS NULL OR k.how <> p_kind))
      AND NOT EXISTS (SELECT 1 FROM bank_transfer_links t WHERE b.id IN (t.a_id, t.b_id))
      AND CASE p_kind
            WHEN 'card' THEN b.account = 'main' AND b.description ~* '^\d{10,}\s+MSP|ELAVON MRCH SVC MSP|^AMEX \d|AMEX\s+\d+\s+MSP|GBL (VI|MC)|CAMBRIDGE MERC|FIRST DATA|ACCEPTPAY|MONERIS|SQUARE'
            WHEN 'etransfer' THEN b.description ~* 'ETRNSFR.*RECVD|ETRNSFR AUTODEPOSIT|E-TRANSFER'
            WHEN 'cheque' THEN b.description ~* 'Branch transaction|MOBILE CHEQUE|Manual Deposit|^Batch|DEPOSIT' AND b.description !~* 'ETRNSFR'
            ELSE b.description ~* 'FINANCEIT|SPL |FINANCING|SNAP|IFINANCE|LENDCARE' AND b.description !~* 'LNS/PRE.*PAYMENT' END;
  -- the app's payments of that kind
  INSERT INTO _pp SELECT p.id, p.received_on, p.amount, NULL FROM payments p
    WHERE p.amount > 0 AND coalesce(p.status, 'succeeded') NOT IN ('failed', 'void', 'voided', 'refunded') AND p.received_on BETWEEN v_from AND v_to
      AND EXISTS (SELECT 1 FROM payment_applications pa WHERE pa.payment_id = p.id)
      AND CASE p_kind
            WHEN 'card' THEN p.method = 'card' AND coalesce(p.notes, '') !~* 'debit'
            WHEN 'etransfer' THEN p.method = 'e_transfer' OR p.notes ~* 'e-?transfer'
            WHEN 'cheque' THEN p.method = 'cheque'
            ELSE p.method = 'financing' END;
  CREATE INDEX IF NOT EXISTS _pp_amt ON _pp (amt); ANALYZE _pp;
  -- 1: one payment = one deposit, the nearest after
  FOR d IN SELECT * FROM _pd ORDER BY dt, id LOOP
    UPDATE _pp SET bank = d.id WHERE id = (SELECT id FROM _pp WHERE bank IS NULL AND amt BETWEEN d.amt - 0.005 AND d.amt + 0.005 AND dt BETWEEN d.dt - fwd AND d.dt + back ORDER BY abs((d.dt - dt) - 1), id LIMIT 1);
    IF FOUND THEN UPDATE _pd SET done = 'one' WHERE id = d.id; n1 := n1 + 1; END IF;
  END LOOP;
  -- 2: all of one day's payments in one deposit (a batch)
  FOR d IN SELECT * FROM _pd WHERE done IS NULL ORDER BY dt, id LOOP
    SELECT dt AS day INTO g FROM _pp WHERE bank IS NULL AND dt BETWEEN d.dt - fwd AND d.dt + back GROUP BY dt HAVING count(*) > 1 AND abs(sum(amt) - d.amt) < 0.01 ORDER BY abs((d.dt - dt) - 1) LIMIT 1;
    IF g.day IS NOT NULL THEN UPDATE _pp SET bank = d.id WHERE bank IS NULL AND dt = g.day; UPDATE _pd SET done = 'day' WHERE id = d.id; nd := nd + 1; END IF;
  END LOOP;
  -- 3: two or three payments added together
  FOR d IN SELECT * FROM _pd WHERE done IS NULL ORDER BY dt, id LOOP
    WITH c AS MATERIALIZED (SELECT id, dt, amt FROM _pp WHERE bank IS NULL AND amt < d.amt AND dt BETWEEN d.dt - fwd AND d.dt + back ORDER BY abs((d.dt - dt) - 1) LIMIT 30)
    SELECT a.id AS k1, b.id AS k2, NULL::bigint AS k3 INTO g FROM c a JOIN c b ON a.id < b.id AND abs(a.amt + b.amt - d.amt) < 0.01 ORDER BY abs(a.dt - b.dt) LIMIT 1;
    IF g.k1 IS NULL THEN
      WITH c AS MATERIALIZED (SELECT id, dt, amt FROM _pp WHERE bank IS NULL AND amt < d.amt AND dt BETWEEN d.dt - fwd AND d.dt + back ORDER BY abs((d.dt - dt) - 1) LIMIT 25)
      SELECT a.id AS k1, b.id AS k2, e.id AS k3 INTO g FROM c a JOIN c b ON a.id < b.id JOIN c e ON b.id < e.id AND abs(a.amt + b.amt + e.amt - d.amt) < 0.01 ORDER BY abs(a.dt - b.dt) + abs(b.dt - e.dt) LIMIT 1;
    END IF;
    IF g.k1 IS NOT NULL THEN UPDATE _pp SET bank = d.id WHERE id IN (g.k1, g.k2, g.k3); UPDATE _pd SET done = 'some' WHERE id = d.id; n2 := n2 + 1; END IF;
  END LOOP;
  -- keep the links (this kind, this year): each deposit -> the invoices its payments went to
  DELETE FROM bank_invoice_links k USING bank_transactions b WHERE b.id = k.bank_id AND k.how = p_kind AND k.partner_id IS NULL AND b.txn_date BETWEEN v_from AND v_to + 30
    AND NOT EXISTS (SELECT 1 FROM _pd WHERE _pd.id = k.bank_id AND _pd.done IS NULL AND false);
  INSERT INTO bank_invoice_links (bank_id, invoice_id, amount, partner_id, how)
    SELECT p.bank, pa.invoice_id, sum(pa.amount), NULL, p_kind FROM _pp p JOIN payment_applications pa ON pa.payment_id = p.id
    WHERE p.bank IS NOT NULL AND pa.invoice_id IS NOT NULL GROUP BY p.bank, pa.invoice_id
    ON CONFLICT (bank_id, invoice_id) DO NOTHING;
  RETURN jsonb_build_object('kind', p_kind, 'year', p_year, 'deposits', (SELECT count(*) FROM _pd WHERE dt <= v_to), 'deposit_sum', (SELECT coalesce(sum(amt), 0) FROM _pd WHERE dt <= v_to),
    'payments', (SELECT count(*) FROM _pp), 'payment_sum', (SELECT coalesce(sum(amt), 0) FROM _pp),
    'matched', (SELECT count(*) FROM _pd WHERE done IS NOT NULL), 'matched_sum', (SELECT coalesce(sum(amt), 0) FROM _pd WHERE done IS NOT NULL),
    'paid_matched', (SELECT count(*) FROM _pp WHERE bank IS NOT NULL), 'one', n1, 'day', nd, 'some', n2);
END $f$;
REVOKE EXECUTE ON FUNCTION public.bank_pay_match(text, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bank_pay_match(text, int) TO authenticated;
NOTIFY pgrst, 'reload schema';

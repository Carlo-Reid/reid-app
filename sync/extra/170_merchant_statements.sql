-- Bank: card processor statements (Elavon "Merchant Billing Statement", one a month per merchant account) loaded on the Bank page.
-- Each statement lists the batches (one bank deposit each) with what each card brand added up to that day, and the month's fees.
-- A batch is tied to its bank deposit, and each brand's amount to the card payments of that brand that day (one, or a few added up),
-- so the deposit gets the invoices those payments went to. The month's fees are tied to the fee debit in the bank.
CREATE TABLE IF NOT EXISTS public.merchant_statements (
  id bigserial PRIMARY KEY, processor text NOT NULL DEFAULT 'Elavon', merchant_no text NOT NULL, statement_date date NOT NULL,
  total_sales numeric(14,2), total_fees numeric(14,2), fee_account text, file_name text, pdf text, loaded_at timestamptz NOT NULL DEFAULT now(), loaded_by bigint,
  UNIQUE (merchant_no, statement_date));
CREATE TABLE IF NOT EXISTS public.merchant_batches (
  id bigserial PRIMARY KEY, statement_id bigint NOT NULL REFERENCES public.merchant_statements(id) ON DELETE CASCADE,
  batch_date date, settle_date date, reference text, batch_no text, total numeric(14,2), brands jsonb NOT NULL DEFAULT '{}',
  bank_id bigint REFERENCES public.bank_transactions(id) ON DELETE SET NULL, matched jsonb, UNIQUE (statement_id, reference, batch_no));
CREATE TABLE IF NOT EXISTS public.merchant_batch_payments (
  batch_id bigint NOT NULL REFERENCES public.merchant_batches(id) ON DELETE CASCADE, payment_id bigint NOT NULL, brand text, PRIMARY KEY (batch_id, payment_id));
CREATE INDEX IF NOT EXISTS merchant_batch_payments_pay ON public.merchant_batch_payments (payment_id);
ALTER TABLE public.merchant_statements ENABLE ROW LEVEL SECURITY; ALTER TABLE public.merchant_batches ENABLE ROW LEVEL SECURITY; ALTER TABLE public.merchant_batch_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.merchant_statements, public.merchant_batches, public.merchant_batch_payments FROM PUBLIC, anon, authenticated;

-- a payment's card brand from what ServiceTitan wrote on it
CREATE OR REPLACE FUNCTION public._pay_brand(n text) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN n ~* '^\s*visa' THEN 'VISA' WHEN n ~* '^\s*master' THEN 'M/C' WHEN n ~* '^\s*(amex|american)' THEN 'AEXP' WHEN n ~* '^\s*disc' THEN 'DISC'
              WHEN n ~* 'debit|interac' THEN 'DEBIT' ELSE 'ANY' END $f$;

-- tie one statement's batches (and fees) to the bank and the app's card payments
CREATE OR REPLACE FUNCTION public.merchant_statement_match(p_id bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off' AS $f$
DECLARE b record; br record; dep bigint; ids bigint[]; need numeric; got numeric; nb int := 0; nd int := 0; np int := 0; nbr int := 0; nbr_ok int := 0; st merchant_statements; fee bigint;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  SELECT * INTO st FROM merchant_statements WHERE id = p_id; IF st.id IS NULL THEN RAISE EXCEPTION 'No such statement'; END IF;
  -- start over for this statement
  DELETE FROM bank_invoice_links k USING merchant_batches mb WHERE mb.statement_id = p_id AND k.bank_id = mb.bank_id AND k.how = 'merchant';
  DELETE FROM merchant_batch_payments mp USING merchant_batches mb WHERE mb.statement_id = p_id AND mp.batch_id = mb.id;
  UPDATE merchant_batches SET bank_id = NULL, matched = NULL WHERE statement_id = p_id;
  FOR b IN SELECT * FROM merchant_batches WHERE statement_id = p_id ORDER BY batch_date, id LOOP
    nb := nb + 1; dep := NULL;
    -- 1: the bank deposit for the batch (same amount, on the settlement day or a few days after)
    SELECT t.id INTO dep FROM bank_transactions t
      WHERE t.amount_in = b.total AND t.txn_date BETWEEN coalesce(b.settle_date, b.batch_date) - 1 AND coalesce(b.settle_date, b.batch_date) + 5
        AND t.description ~* 'ELAVON|MSP/DIV|MRCH' AND NOT EXISTS (SELECT 1 FROM merchant_batches o WHERE o.bank_id = t.id AND o.id <> b.id)
      ORDER BY abs(t.txn_date - coalesce(b.settle_date, b.batch_date)), t.id LIMIT 1;
    IF dep IS NOT NULL THEN nd := nd + 1; UPDATE merchant_batches SET bank_id = dep WHERE id = b.id; END IF;
    -- 2: each card brand's amount = that brand's card payments that day (one, two or three added up, or all of them)
    FOR br IN SELECT key AS brand, value::numeric AS amt FROM jsonb_each_text(b.brands) WHERE value::numeric > 0 LOOP
      nbr := nbr + 1; need := br.amt; ids := NULL; dep := dep;
      CREATE TEMP TABLE IF NOT EXISTS _mc (id bigint, amt numeric, dt date) ON COMMIT DROP; TRUNCATE _mc;
      INSERT INTO _mc SELECT p.id, p.amount, p.received_on FROM payments p
        WHERE p.method = 'card' AND p.amount > 0 AND coalesce(p.status, 'succeeded') NOT IN ('failed', 'void', 'voided', 'refunded')
          AND p.received_on BETWEEN b.batch_date - 3 AND b.batch_date
          AND public._pay_brand(p.notes) IN (br.brand, 'ANY') AND NOT EXISTS (SELECT 1 FROM merchant_batch_payments m WHERE m.payment_id = p.id);
      SELECT ARRAY[a.id] INTO ids FROM _mc a WHERE abs(a.amt - need) < 0.005 ORDER BY (a.dt = b.batch_date) DESC, a.id LIMIT 1;
      IF ids IS NULL THEN SELECT ARRAY[a.id, c.id] INTO ids FROM _mc a JOIN _mc c ON a.id < c.id AND abs(a.amt + c.amt - need) < 0.005 LIMIT 1; END IF;
      IF ids IS NULL THEN SELECT ARRAY[a.id, c.id, e.id] INTO ids FROM _mc a JOIN _mc c ON a.id < c.id JOIN _mc e ON c.id < e.id AND abs(a.amt + c.amt + e.amt - need) < 0.005 LIMIT 1; END IF;
      IF ids IS NULL THEN SELECT array_agg(id) INTO ids FROM _mc WHERE dt = b.batch_date HAVING abs(sum(amt) - need) < 0.005; END IF;
      IF ids IS NOT NULL THEN nbr_ok := nbr_ok + 1;
        INSERT INTO merchant_batch_payments (batch_id, payment_id, brand) SELECT b.id, unnest(ids), br.brand ON CONFLICT DO NOTHING; np := np + coalesce(array_length(ids, 1), 0); END IF;
    END LOOP;
    UPDATE merchant_batches SET matched = jsonb_build_object('brands', (SELECT count(*) FROM jsonb_each(b.brands)),
      'paid', (SELECT coalesce(sum(p.amount), 0) FROM merchant_batch_payments m JOIN payments p ON p.id = m.payment_id WHERE m.batch_id = b.id)) WHERE id = b.id;
    -- 3: the deposit gets the invoices those payments went to (in place of a guessed card match)
    IF dep IS NOT NULL THEN
      DELETE FROM bank_invoice_links WHERE bank_id = dep AND how = 'card';
      INSERT INTO bank_invoice_links (bank_id, invoice_id, amount, partner_id, how)
        SELECT dep, pa.invoice_id, sum(pa.amount), NULL, 'merchant' FROM merchant_batch_payments m JOIN payment_applications pa ON pa.payment_id = m.payment_id
        WHERE m.batch_id = b.id AND pa.invoice_id IS NOT NULL GROUP BY pa.invoice_id
        ON CONFLICT (bank_id, invoice_id) DO UPDATE SET how = 'merchant', amount = EXCLUDED.amount;
    END IF;
  END LOOP;
  -- 4: the month's fees: the fee debit in the bank (same amount, early the next month) gets the statement attached
  IF coalesce(st.total_fees, 0) > 0 THEN
    SELECT t.id INTO fee FROM bank_transactions t WHERE t.amount_out = st.total_fees AND t.txn_date BETWEEN st.statement_date - 2 AND st.statement_date + 12
      AND t.description ~* 'ELAVON|MRCH|CMS/GES|MERCH' ORDER BY abs(t.txn_date - st.statement_date - 2) LIMIT 1;
    IF fee IS NOT NULL THEN
      DELETE FROM bank_files WHERE bank_id = fee AND name = coalesce(st.file_name, 'Merchant statement.pdf');
      INSERT INTO bank_files (bank_id, name, mime, data, size) SELECT fee, coalesce(st.file_name, 'Merchant statement.pdf'), 'application/pdf', st.pdf, (length(st.pdf) * 3 / 4)::int WHERE st.pdf IS NOT NULL;
      UPDATE bank_transactions SET note = coalesce(nullif(note, ''), 'Card processing fees, ' || to_char(st.statement_date, 'FMMonth YYYY') || ' (merchant ' || right(st.merchant_no, 4) || ')') WHERE id = fee;
    END IF;
  END IF;
  RETURN jsonb_build_object('batches', nb, 'deposits', nd, 'brands', nbr, 'brands_matched', nbr_ok, 'payments', np, 'fee_line', fee,
    'invoices', (SELECT count(*) FROM bank_invoice_links k JOIN merchant_batches mb ON mb.bank_id = k.bank_id WHERE mb.statement_id = p_id AND k.how = 'merchant'));
END $f$;

-- save a statement read from the PDF in the browser (replaces the same merchant's same month), then match it
CREATE OR REPLACE FUNCTION public.merchant_statement_save(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v bigint; x jsonb;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  IF nullif(p ->> 'merchant_no', '') IS NULL OR (p ->> 'statement_date') IS NULL THEN RAISE EXCEPTION 'Couldn''t read the merchant number or the statement date'; END IF;
  IF jsonb_typeof(p -> 'batches') <> 'array' OR jsonb_array_length(p -> 'batches') = 0 THEN RAISE EXCEPTION 'No deposits (batches) found on the statement'; END IF;
  DELETE FROM merchant_statements WHERE merchant_no = p ->> 'merchant_no' AND statement_date = (p ->> 'statement_date')::date;
  INSERT INTO merchant_statements (processor, merchant_no, statement_date, total_sales, total_fees, fee_account, file_name, pdf, loaded_by)
  VALUES (coalesce(p ->> 'processor', 'Elavon'), p ->> 'merchant_no', (p ->> 'statement_date')::date, (p ->> 'total_sales')::numeric, (p ->> 'total_fees')::numeric, p ->> 'fee_account', p ->> 'file_name', p ->> 'pdf', public.current_app_user_id())
  RETURNING id INTO v;
  FOR x IN SELECT * FROM jsonb_array_elements(p -> 'batches') LOOP
    INSERT INTO merchant_batches (statement_id, batch_date, settle_date, reference, batch_no, total, brands)
    VALUES (v, (x ->> 'batch_date')::date, (x ->> 'settle_date')::date, x ->> 'reference', x ->> 'batch_no', (x ->> 'total')::numeric, coalesce(x -> 'brands', '{}'))
    ON CONFLICT DO NOTHING;
  END LOOP;
  RETURN jsonb_build_object('id', v) || public.merchant_statement_match(v);
END $f$;

CREATE OR REPLACE FUNCTION public.merchant_statements_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._bank_owner() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'merchant_no', s.merchant_no, 'date', s.statement_date, 'sales', s.total_sales, 'fees', s.total_fees, 'file', s.file_name,
      'batches', (SELECT count(*) FROM merchant_batches b WHERE b.statement_id = s.id), 'deposits', (SELECT count(*) FROM merchant_batches b WHERE b.statement_id = s.id AND b.bank_id IS NOT NULL),
      'paid', (SELECT count(*) FROM merchant_batches b WHERE b.statement_id = s.id AND abs(coalesce((b.matched ->> 'paid')::numeric, 0) - b.total) < 0.01),
      'invoices', (SELECT count(*) FROM bank_invoice_links k JOIN merchant_batches b ON b.bank_id = k.bank_id WHERE b.statement_id = s.id AND k.how = 'merchant'),
      'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('date', b.batch_date, 'total', b.total, 'brands', b.brands, 'bank', b.bank_id, 'paid', (b.matched ->> 'paid')::numeric) ORDER BY b.batch_date), '[]') FROM merchant_batches b WHERE b.statement_id = s.id))
    ORDER BY s.statement_date DESC, s.merchant_no) FROM merchant_statements s), '[]') END $f$;

REVOKE EXECUTE ON FUNCTION public.merchant_statement_match(bigint), public.merchant_statement_save(jsonb), public.merchant_statements_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.merchant_statement_match(bigint), public.merchant_statement_save(jsonb), public.merchant_statements_list() TO authenticated;

-- the card guesser leaves alone the payments a statement has placed
DO $do$
DECLARE src text := pg_get_functiondef('public.bank_pay_match(text, integer)'::regprocedure);
BEGIN
  IF src LIKE '%merchant_batch_payments%' THEN RETURN; END IF;
  src := replace(src, $a$      AND EXISTS (SELECT 1 FROM payment_applications pa WHERE pa.payment_id = p.id)$a$,
                      $a$      AND EXISTS (SELECT 1 FROM payment_applications pa WHERE pa.payment_id = p.id) AND NOT EXISTS (SELECT 1 FROM merchant_batch_payments mbp WHERE mbp.payment_id = p.id)$a$);
  IF src NOT LIKE '%merchant_batch_payments%' THEN RAISE EXCEPTION 'bank_pay_match: anchor not found'; END IF;
  EXECUTE src;
END $do$;
NOTIFY pgrst, 'reload schema';

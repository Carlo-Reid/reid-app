-- Bank: the bank account's transactions (loaded from the bank's export), for owners only.
-- Search and filter them, totals by kind and month, and match partners' deposits (Vista, Costco, Rona, Lowe's) to the payments in the app.
CREATE TABLE IF NOT EXISTS public.bank_transactions (
  id bigserial PRIMARY KEY,
  account text NOT NULL DEFAULT 'main',
  txn_date date NOT NULL,
  code text NOT NULL DEFAULT '',
  description text NOT NULL DEFAULT '',
  amount_out numeric(14,2) NOT NULL DEFAULT 0,
  amount_in numeric(14,2) NOT NULL DEFAULT 0,
  balance numeric(14,2),
  file_name text,
  loaded_at timestamptz NOT NULL DEFAULT now(),
  loaded_by bigint,
  note text
);
CREATE UNIQUE INDEX IF NOT EXISTS bank_transactions_one ON public.bank_transactions (account, txn_date, description, amount_out, amount_in, coalesce(balance, 0));
CREATE INDEX IF NOT EXISTS bank_transactions_date ON public.bank_transactions (txn_date);
ALTER TABLE public.bank_transactions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.bank_transactions FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._bank_owner() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(public.current_staff_role() = 'owner', false) $f$;

-- what kind of transaction it is, from the bank's description
CREATE OR REPLACE FUNCTION public._bank_cat(d text, code text DEFAULT '', amt_in numeric DEFAULT 0) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE
    WHEN d ~* 'VISTACREDIT|COSTCO|RONA INC|LOWE|GRAND HVAC|FINANCEIT|360INSIGHTS|CLEARESULT|CONFIDENT REMOD|HOME DEPOT' THEN 'Partners & financing'
    WHEN d ~* '^\d{10,}\s+MSP|ELAVON MRCH SVC MSP|ACCEPTPAY|EFT CANADA|^AMEX \d|GBL (VI|MC)|CAMBRIDGE MERC|FIRST DATA' AND amt_in > 0 THEN 'Card & online payments in'
    WHEN d ~* 'ELAVON MRCH SVC CMS|MERCH FEES|PLAN FEE|O/D FACILITY|FACILITY FEE|^Interest|APPLICATION FEE|RETURNED ITEM|DISCOUNT \d+ AT|SERVICE CHARGE|^USD NOTES' OR code IN ('SC') THEN 'Bank & card fees'
    WHEN d ~* 'Branch transaction|Manual Deposit|MOBILE CHEQUE|^Batch|ETRNSFR RECVD|Insur\w* Payment|CITY OF OTTAWA' OR (d ~ '^\s*$' AND amt_in > 0) THEN 'Deposits'
    WHEN d ~* 'LENNOX|GROUPE MASTER|LINDE|GOODMAN|DAIKIN|WOLSELEY|LENINDGF|BOONE|TRENT|EMCO|CONVEX|NOBLE|REDMOND|ADI ' THEN 'Suppliers'
    WHEN d ~* '^NO\.\s?\d' OR code = 'CK' THEN 'Cheques'
    WHEN d ~* '^PC MC|PC FINANCIAL|BMO MASTERCARD|AMEX CARDS|AMEX CREDIT|M/C-CIBC' THEN 'Credit cards'
    WHEN d ~* 'FORD CREDIT|SPL LNS|RBC LOAN|TD LOAN|BNS MTGE|JPLEASING|HYUNDAI|BMO LOC|^DRAFT|LNS/PRE' THEN 'Loans & leases'
    WHEN d ~* 'CANACT|EMPTX|WSIB|GST-P|OTTAWA TAXES|REVENUE' THEN 'Taxes & government'
    WHEN d ~* 'ETRNSFR SENT|FAMILY RESP' THEN 'e-Transfers sent'
    WHEN d ~* 'DOMINION PREM|AVIVA|TRAVELERS|VICTOR INS|MANULIFE|COMBINED INS|CANLIFE|INS/ASS' THEN 'Insurance'
    WHEN d ~* '^WEX|ESSO' THEN 'Fuel'
    WHEN d ~* 'PREMIERE PROP|CARLETON CONDOM|SOMERVILLE|LPT REALTY' THEN 'Rent & property'
    WHEN d ~* 'HYDRO OTTAWA|ENBRIDGE|BELL |OTTAWA WATSWR|ROGERS|TELUS' THEN 'Utilities & phone'
    WHEN d ~* '^TF \d|M-?FUNDS|MFUNDS' THEN 'Transfers'
    ELSE 'Other' END $f$;

-- load rows from the bank's export (the same row twice is only kept once)
CREATE OR REPLACE FUNCTION public.bank_import(p_rows jsonb, p_file text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int := 0; t int := 0; x jsonb;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can load the bank'; END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    t := t + 1;
    INSERT INTO bank_transactions (txn_date, code, description, amount_out, amount_in, balance, file_name, loaded_by)
    VALUES ((x ->> 'date')::date, coalesce(x ->> 'code', ''), btrim(coalesce(x ->> 'description', '')), coalesce((x ->> 'out')::numeric, 0), coalesce((x ->> 'in')::numeric, 0),
            (x ->> 'balance')::numeric, p_file, public.current_app_user_id())
    ON CONFLICT DO NOTHING;
    IF FOUND THEN n := n + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('read', t, 'added', n, 'already', t - n);
END $f$;

-- the list: search words or an amount, dates, kind, in/out
CREATE OR REPLACE FUNCTION public.bank_list(p_q text DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_cat text DEFAULT NULL, p_dir text DEFAULT NULL, p_limit int DEFAULT 300, p_offset int DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE q text := nullif(btrim(coalesce(p_q, '')), ''); amt numeric; r jsonb;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can see the bank'; END IF;
  IF q ~ '^\$?[\d,]+(\.\d{1,2})?$' THEN amt := replace(replace(q, '$', ''), ',', '')::numeric; END IF;
  WITH f AS (
    SELECT b.*, public._bank_cat(b.description, b.code, b.amount_in) AS cat FROM bank_transactions b
    WHERE (p_from IS NULL OR b.txn_date >= p_from) AND (p_to IS NULL OR b.txn_date <= p_to)
      AND (p_dir IS NULL OR (p_dir = 'in' AND b.amount_in > 0) OR (p_dir = 'out' AND b.amount_out > 0))
      AND (q IS NULL OR (amt IS NOT NULL AND (b.amount_in = amt OR b.amount_out = amt)) OR b.description ILIKE '%' || q || '%' OR b.code ILIKE q OR b.note ILIKE '%' || q || '%')),
  g AS (SELECT * FROM f WHERE p_cat IS NULL OR cat = p_cat)
  SELECT jsonb_build_object(
    'count', (SELECT count(*) FROM g), 'in', (SELECT coalesce(sum(amount_in), 0) FROM g), 'out', (SELECT coalesce(sum(amount_out), 0) FROM g),
    'cats', (SELECT coalesce(jsonb_agg(jsonb_build_object('cat', cat, 'n', n, 'in', i, 'out', o) ORDER BY i + o DESC), '[]') FROM (SELECT cat, count(*) n, sum(amount_in) i, sum(amount_out) o FROM f GROUP BY cat) c),
    'first', (SELECT min(txn_date) FROM bank_transactions), 'last', (SELECT max(txn_date) FROM bank_transactions), 'all', (SELECT count(*) FROM bank_transactions),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'date', txn_date, 'code', code, 'description', description, 'out', amount_out, 'in', amount_in, 'balance', balance, 'cat', cat, 'note', note)
              ORDER BY txn_date DESC, id DESC), '[]') FROM (SELECT * FROM g ORDER BY txn_date DESC, id DESC LIMIT least(coalesce(p_limit, 300), 2000) OFFSET coalesce(p_offset, 0)) x)) INTO r;
  RETURN r;
END $f$;

-- totals by kind and month for a year, and who it went to / came from
CREATE OR REPLACE FUNCTION public.bank_summary(p_year int DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE r jsonb;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can see the bank'; END IF;
  WITH f AS (SELECT b.*, public._bank_cat(b.description, b.code, b.amount_in) AS cat,
                    btrim(regexp_replace(regexp_replace(b.description, '\d{3,}[-#\d]*', '#', 'g'), '\s+', ' ', 'g')) AS who
             FROM bank_transactions b WHERE p_year IS NULL OR extract(year FROM b.txn_date) = p_year)
  SELECT jsonb_build_object(
    'years', (SELECT jsonb_agg(y ORDER BY y DESC) FROM (SELECT DISTINCT extract(year FROM txn_date)::int y FROM bank_transactions) z),
    'in', (SELECT coalesce(sum(amount_in), 0) FROM f), 'out', (SELECT coalesce(sum(amount_out), 0) FROM f),
    'months', (SELECT coalesce(jsonb_agg(jsonb_build_object('m', m, 'in', i, 'out', o) ORDER BY m), '[]') FROM (SELECT to_char(txn_date, 'YYYY-MM') m, sum(amount_in) i, sum(amount_out) o FROM f GROUP BY 1) a),
    'cats', (SELECT coalesce(jsonb_agg(jsonb_build_object('cat', cat, 'n', n, 'in', i, 'out', o, 'months', ms) ORDER BY i + o DESC), '[]') FROM
               (SELECT cat, count(*) n, sum(amount_in) i, sum(amount_out) o,
                       (SELECT jsonb_object_agg(m, v) FROM (SELECT to_char(f2.txn_date, 'YYYY-MM') m, sum(f2.amount_in - f2.amount_out) v FROM f f2 WHERE f2.cat = f.cat GROUP BY 1) mm) ms
                FROM f GROUP BY cat) c),
    'top_in', (SELECT coalesce(jsonb_agg(jsonb_build_object('who', who, 'n', n, 'sum', s) ORDER BY s DESC), '[]') FROM (SELECT who, count(*) n, sum(amount_in) s FROM f WHERE amount_in > 0 GROUP BY who ORDER BY 3 DESC LIMIT 25) a),
    'top_out', (SELECT coalesce(jsonb_agg(jsonb_build_object('who', who, 'n', n, 'sum', s) ORDER BY s DESC), '[]') FROM (SELECT who, count(*) n, sum(amount_out) s FROM f WHERE amount_out > 0 GROUP BY who ORDER BY 3 DESC LIMIT 25) a)) INTO r;
  RETURN r;
END $f$;

-- a note on a bank line (what it was for)
CREATE OR REPLACE FUNCTION public.bank_note_set(p_id bigint, p_note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  UPDATE bank_transactions SET note = nullif(btrim(coalesce(p_note, '')), '') WHERE id = p_id;
END $f$;

-- a partner's deposits in the bank next to the payments the app has from them:
-- the app's payments are grouped by their remittance # (or by day), and each group is matched to a deposit of the same amount
CREATE OR REPLACE FUNCTION public.bank_partner_match(p_partner bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off' AS $f$
DECLARE pat text; word text; v_first date; v_last date; d record; g record; r jsonb;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can see the bank'; END IF;
  SELECT CASE WHEN name ~* 'vista' THEN 'VISTACREDIT' WHEN name ~* 'costco' THEN 'COSTCO' WHEN name ~* 'rona' THEN 'RONA INC' WHEN name ~* 'lowe' THEN 'LOWE' ELSE upper(split_part(name, ' ', 1)) END,
         split_part(name, ' ', 1) INTO pat, word FROM partners WHERE id = p_partner;
  IF pat IS NULL THEN RAISE EXCEPTION 'No such partner'; END IF;
  SELECT min(txn_date), max(txn_date) INTO v_first, v_last FROM bank_transactions;
  CREATE TEMP TABLE IF NOT EXISTS _bd (id bigint, dt date, amt numeric, grp text) ON COMMIT DROP; TRUNCATE _bd;
  CREATE TEMP TABLE IF NOT EXISTS _ag (k text, dt date, dt2 date, amt numeric, n int, ids bigint[], refs text, bank bigint) ON COMMIT DROP; TRUNCATE _ag;
  INSERT INTO _bd SELECT id, txn_date, amount_in, NULL FROM bank_transactions WHERE amount_in > 0 AND description ILIKE pat || '%';
  INSERT INTO _ag (k, dt, dt2, amt, n, ids, refs)
    SELECT k, min(received_on), max(received_on), sum(amount), count(*), array_agg(id), string_agg(DISTINCT ref, ', ')
    FROM (SELECT p.id, p.received_on, p.amount,
                 upper(nullif(regexp_replace(coalesce(nullif(btrim(p.reference), ''), substring(p.notes FROM '[Rr]\d{4,}'), ''), '\s', '', 'g'), '')) AS ref,
                 coalesce(upper(nullif(regexp_replace(coalesce(nullif(btrim(p.reference), ''), substring(p.notes FROM '[Rr]\d{4,}'), ''), '\s', '', 'g'), '')), 'DAY ' || p.received_on) AS k
          FROM payments p
          WHERE coalesce(p.status, 'succeeded') NOT IN ('failed', 'void', 'voided', 'refunded') AND p.amount > 0
            AND p.received_on BETWEEN v_first - 45 AND v_last + 10
            AND (EXISTS (SELECT 1 FROM payment_applications pa JOIN invoices i ON i.id = pa.invoice_id WHERE pa.payment_id = p.id AND i.bill_to_partner_id = p_partner)
                 OR (p.method = 'partner_remittance' AND p.notes ILIKE '%' || word || '%'))) s
    GROUP BY k;
  -- 1: one group = one deposit, closest date first
  FOR d IN SELECT * FROM _bd ORDER BY dt, id LOOP
    UPDATE _ag SET bank = d.id WHERE k = (SELECT k FROM _ag WHERE bank IS NULL AND abs(amt - d.amt) < 0.01 AND dt BETWEEN d.dt - 30 AND d.dt + 20 ORDER BY abs(dt - d.dt), k LIMIT 1);
    IF FOUND THEN UPDATE _bd SET grp = 'one' WHERE id = d.id; END IF;
  END LOOP;
  -- 2: a deposit that is two groups added together
  FOR d IN SELECT * FROM _bd WHERE grp IS NULL ORDER BY dt, id LOOP
    SELECT a.k AS k1, b.k AS k2 INTO g FROM _ag a JOIN _ag b ON a.k < b.k
      WHERE a.bank IS NULL AND b.bank IS NULL AND abs(a.amt + b.amt - d.amt) < 0.01 AND a.dt BETWEEN d.dt - 30 AND d.dt + 20 AND b.dt BETWEEN d.dt - 30 AND d.dt + 20
      ORDER BY abs(a.dt - d.dt) + abs(b.dt - d.dt) LIMIT 1;
    IF g.k1 IS NOT NULL THEN UPDATE _ag SET bank = d.id WHERE k IN (g.k1, g.k2); UPDATE _bd SET grp = 'two' WHERE id = d.id; END IF;
  END LOOP;
  SELECT jsonb_build_object(
    'partner', (SELECT name FROM partners WHERE id = p_partner), 'pattern', pat, 'first', v_first, 'last', v_last,
    'bank_n', (SELECT count(*) FROM _bd), 'bank_sum', (SELECT coalesce(sum(amt), 0) FROM _bd),
    'app_n', (SELECT coalesce(sum(n), 0) FROM _ag WHERE dt BETWEEN v_first AND v_last), 'app_sum', (SELECT coalesce(sum(amt), 0) FROM _ag WHERE dt BETWEEN v_first AND v_last),
    'matched_n', (SELECT count(*) FROM _bd WHERE grp IS NOT NULL), 'matched_sum', (SELECT coalesce(sum(amt), 0) FROM _bd WHERE grp IS NOT NULL),
    'open_n', (SELECT count(*) FROM invoices WHERE bill_to_partner_id = p_partner AND balance_due > 0.004 AND status NOT IN ('void', 'draft')),
    'open_sum', (SELECT coalesce(sum(balance_due), 0) FROM invoices WHERE bill_to_partner_id = p_partner AND balance_due > 0.004 AND status NOT IN ('void', 'draft')),
    -- money in the bank the app doesn't have as a payment (an invoice may still show owing for it)
    'bank_only', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'date', b.dt, 'amount', b.amt,
                    'maybe', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.invoice_number, 'date', i.invoice_date, 'balance', i.balance_due,
                                 'who', (SELECT display_name FROM customers WHERE id = (SELECT customer_id FROM locations WHERE id = i.location_id)))), '[]')
                              FROM (SELECT * FROM invoices i WHERE i.bill_to_partner_id = p_partner AND i.status NOT IN ('void', 'draft') AND abs(i.balance_due - b.amt) < 0.01
                                    AND i.invoice_date <= b.dt ORDER BY i.invoice_date DESC LIMIT 3) i)) ORDER BY b.dt DESC), '[]') FROM _bd b WHERE b.grp IS NULL),
    -- payments in the app with no deposit of that amount in the bank
    'app_only', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', k, 'date', dt, 'amount', amt, 'n', n, 'refs', refs,
                    'invoices', (SELECT jsonb_agg(DISTINCT i.invoice_number) FROM payment_applications pa JOIN invoices i ON i.id = pa.invoice_id WHERE pa.payment_id = ANY (ids))) ORDER BY dt DESC), '[]')
                 FROM _ag WHERE bank IS NULL AND dt BETWEEN v_first AND v_last),
    'matched', (SELECT coalesce(jsonb_agg(jsonb_build_object('date', b.dt, 'amount', b.amt, 'how', b.grp,
                    'refs', (SELECT string_agg(coalesce(a.refs, a.k), ' + ') FROM _ag a WHERE a.bank = b.id), 'n', (SELECT sum(a.n) FROM _ag a WHERE a.bank = b.id)) ORDER BY b.dt DESC), '[]')
                FROM (SELECT * FROM _bd WHERE grp IS NOT NULL ORDER BY dt DESC LIMIT 400) b)) INTO r;
  RETURN r;
END $f$;

REVOKE EXECUTE ON FUNCTION public.bank_import(jsonb, text), public.bank_list(text, date, date, text, text, int, int), public.bank_summary(int), public.bank_note_set(bigint, text), public.bank_partner_match(bigint), public._bank_owner() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bank_import(jsonb, text), public.bank_list(text, date, date, text, text, int, int), public.bank_summary(int), public.bank_note_set(bigint, text), public.bank_partner_match(bigint), public._bank_owner() TO authenticated;
NOTIFY pgrst, 'reload schema';

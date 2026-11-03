-- Partner deposits: only the partner's remittances are matched (a homeowner's card, cheque or e-Transfer on a partner invoice goes with those deposits);
-- a remittance # is read by its digits (R14825 = T14825); and a deposit a bit bigger than its remittances is matched with the gap shown,
-- next to any open invoice for exactly that gap (the payment the app is missing).
CREATE OR REPLACE FUNCTION public.bank_partner_match(p_partner bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off' SET statement_timeout TO '60s' AS $f$
DECLARE pat text; word text; v_first date; v_last date; d record; g record; r jsonb;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can see the bank'; END IF;
  SELECT CASE WHEN name ~* 'vista' THEN 'VISTACREDIT' WHEN name ~* 'costco' THEN 'COSTCO' WHEN name ~* 'rona' THEN 'RONA INC' WHEN name ~* 'lowe' THEN 'LOWE' ELSE upper(split_part(name, ' ', 1)) END,
         split_part(name, ' ', 1) INTO pat, word FROM partners WHERE id = p_partner;
  IF pat IS NULL THEN RAISE EXCEPTION 'No such partner'; END IF;
  SELECT min(txn_date), max(txn_date) INTO v_first, v_last FROM bank_transactions;
  CREATE TEMP TABLE IF NOT EXISTS _bd (id bigint, dt date, amt numeric, grp text) ON COMMIT DROP; TRUNCATE _bd;
  CREATE TEMP TABLE IF NOT EXISTS _ag (k text, dt date, dt2 date, amt numeric, n int, ids bigint[], refs text, bank bigint) ON COMMIT DROP; TRUNCATE _ag;
  -- deposits in either account
  INSERT INTO _bd SELECT id, txn_date, amount_in, NULL FROM bank_transactions WHERE amount_in > 0 AND description ILIKE pat || '%';
  -- the app's payments from this partner: on an invoice billed to (or done for) the partner, or a remittance named for it
  CREATE TEMP TABLE IF NOT EXISTS _pid (id bigint PRIMARY KEY) ON COMMIT DROP; TRUNCATE _pid;
  INSERT INTO _pid SELECT DISTINCT pa.payment_id FROM payment_applications pa JOIN invoices i ON i.id = pa.invoice_id LEFT JOIN jobs j ON j.id = i.job_id JOIN payments py ON py.id = pa.payment_id
    WHERE (i.bill_to_partner_id = p_partner OR i.branding_partner_id = p_partner OR j.partner_id = p_partner) AND pa.payment_id IS NOT NULL
      AND coalesce(py.method, '') NOT IN ('card', 'e_transfer', 'cheque', 'financing', 'autopay', 'cash') ON CONFLICT DO NOTHING;
  INSERT INTO _pid SELECT id FROM payments WHERE method = 'partner_remittance' AND notes ILIKE word || '%' ON CONFLICT DO NOTHING;
  INSERT INTO _ag (k, dt, dt2, amt, n, ids, refs)
    SELECT k, min(received_on), max(received_on), sum(amount), count(*), array_agg(id), string_agg(DISTINCT ref, ', ')
    FROM (SELECT p.id, p.received_on, p.amount,
                 upper(nullif(regexp_replace(coalesce(nullif(btrim(p.reference), ''), substring(p.notes FROM '[Rr]\d{4,}'), ''), '\s', '', 'g'), '')) AS ref,
                 coalesce(CASE WHEN coalesce(nullif(btrim(p.reference), ''), substring(p.notes FROM '[A-Za-z]?\d{4,}')) ~ '^\s*[A-Za-z]?\d{4,6}\s*$' THEN 'R' || regexp_replace(coalesce(nullif(btrim(p.reference), ''), substring(p.notes FROM '[A-Za-z]?\d{4,}')), '\D', '', 'g') END, upper(nullif(regexp_replace(coalesce(nullif(btrim(p.reference), ''), substring(p.notes FROM '[Rr]\d{4,}'), ''), '\s', '', 'g'), '')), 'DAY ' || p.received_on) AS k
          FROM payments p JOIN _pid USING (id)
          WHERE coalesce(p.status, 'succeeded') NOT IN ('failed', 'void', 'voided', 'refunded') AND p.amount > 0
            AND p.received_on BETWEEN v_first - 45 AND v_last + 10) s
    GROUP BY k;
  -- remittances entered on the Partners page
  INSERT INTO _ag (k, dt, dt2, amt, n, ids, refs)
    SELECT 'PR' || r.id, r.received_on, r.received_on, r.amount, 1, '{}', coalesce(nullif(r.reference, ''), 'entered in the app')
    FROM partner_remittances r WHERE r.partner_id = p_partner AND r.received_on BETWEEN v_first - 45 AND v_last + 10;
  -- 1: one group = one deposit, closest date first
  FOR d IN SELECT * FROM _bd ORDER BY dt, id LOOP
    UPDATE _ag SET bank = d.id WHERE k = (SELECT k FROM _ag WHERE bank IS NULL AND amt BETWEEN d.amt - 0.01 AND d.amt + 0.01 AND dt BETWEEN d.dt - 30 AND d.dt + 20 ORDER BY abs(dt - d.dt), k LIMIT 1);
    IF FOUND THEN UPDATE _bd SET grp = 'one' WHERE id = d.id; END IF;
  END LOOP;
  -- 2: a deposit that is two groups added together
  FOR d IN SELECT * FROM _bd WHERE grp IS NULL ORDER BY dt, id LOOP
    WITH c AS MATERIALIZED (SELECT k, dt, amt FROM _ag WHERE bank IS NULL AND amt < d.amt AND dt BETWEEN d.dt - 30 AND d.dt + 20)
    SELECT a.k AS k1, b.k AS k2 INTO g FROM c a JOIN c b ON a.k < b.k AND abs(a.amt + b.amt - d.amt) < 0.01
      ORDER BY abs(a.dt - d.dt) + abs(b.dt - d.dt) LIMIT 1;
    IF g.k1 IS NOT NULL THEN UPDATE _ag SET bank = d.id WHERE k IN (g.k1, g.k2); UPDATE _bd SET grp = 'two' WHERE id = d.id; END IF;
  END LOOP;
  -- 3: a deposit that is three groups added together (close in date)
  FOR d IN SELECT * FROM _bd WHERE grp IS NULL ORDER BY dt, id LOOP
    WITH c AS MATERIALIZED (SELECT k, dt, amt FROM _ag WHERE bank IS NULL AND amt < d.amt AND dt BETWEEN d.dt - 21 AND d.dt + 10 ORDER BY abs(dt - d.dt) LIMIT 40)
    SELECT a.k AS k1, b.k AS k2, e.k AS k3 INTO g FROM c a JOIN c b ON a.k < b.k JOIN c e ON b.k < e.k AND abs(a.amt + b.amt + e.amt - d.amt) < 0.01
      ORDER BY abs(a.dt - d.dt) + abs(b.dt - d.dt) + abs(e.dt - d.dt) LIMIT 1;
    IF g.k1 IS NOT NULL THEN UPDATE _ag SET bank = d.id WHERE k IN (g.k1, g.k2, g.k3); UPDATE _bd SET grp = 'three' WHERE id = d.id; END IF;
  END LOOP;
  -- 4: a deposit that's a bit more than one or two remittances (the app is missing a payment or two): matched, and the gap shown
  FOR d IN SELECT * FROM _bd WHERE grp IS NULL ORDER BY dt, id LOOP
    WITH c AS MATERIALIZED (SELECT k, dt, amt FROM _ag WHERE bank IS NULL AND amt <= d.amt AND amt >= d.amt * 0.6 AND dt BETWEEN d.dt - 21 AND d.dt + 10),
         c2 AS MATERIALIZED (SELECT k, dt, amt FROM _ag WHERE bank IS NULL AND amt < d.amt AND dt BETWEEN d.dt - 21 AND d.dt + 10 ORDER BY abs(dt - d.dt) LIMIT 30)
    SELECT * INTO g FROM (SELECT k AS k1, NULL::text AS k2, amt AS s FROM c UNION ALL
                          SELECT a.k, b.k, a.amt + b.amt FROM c2 a JOIN c2 b ON a.k < b.k WHERE a.amt + b.amt <= d.amt AND a.amt + b.amt >= d.amt * 0.8) z
      ORDER BY d.amt - s LIMIT 1;
    IF g.k1 IS NOT NULL THEN UPDATE _ag SET bank = d.id WHERE k IN (g.k1, g.k2); UPDATE _bd SET grp = 'partial' WHERE id = d.id; END IF;
  END LOOP;
  -- keep the links: each matched deposit and the invoices its payments went to (the Ledger shows them)
  DELETE FROM bank_invoice_links WHERE partner_id = p_partner;
  INSERT INTO bank_invoice_links (bank_id, invoice_id, amount, partner_id, how)
    SELECT a.bank, pa.invoice_id, sum(pa.amount), p_partner, max(b.grp) FROM _ag a JOIN _bd b ON b.id = a.bank
      JOIN payment_applications pa ON pa.payment_id = ANY (a.ids) WHERE a.bank IS NOT NULL AND pa.invoice_id IS NOT NULL GROUP BY a.bank, pa.invoice_id
    ON CONFLICT (bank_id, invoice_id) DO UPDATE SET amount = EXCLUDED.amount, partner_id = EXCLUDED.partner_id, how = EXCLUDED.how;
  INSERT INTO bank_invoice_links (bank_id, invoice_id, amount, partner_id, how)
    SELECT a.bank, l.invoice_id, sum(l.amount), p_partner, 'remittance' FROM _ag a JOIN partner_remittance_lines l ON a.k LIKE 'PR%' AND l.remittance_id = substr(a.k, 3)::bigint
      WHERE a.bank IS NOT NULL GROUP BY a.bank, l.invoice_id
    ON CONFLICT (bank_id, invoice_id) DO NOTHING;
  SELECT jsonb_build_object(
    'partner', (SELECT name FROM partners WHERE id = p_partner), 'pattern', pat, 'first', v_first, 'last', v_last,
    'bank_n', (SELECT count(*) FROM _bd), 'bank_sum', (SELECT coalesce(sum(amt), 0) FROM _bd),
    'app_n', (SELECT coalesce(sum(n), 0) FROM _ag WHERE dt BETWEEN v_first AND v_last), 'app_sum', (SELECT coalesce(sum(amt), 0) FROM _ag WHERE dt BETWEEN v_first AND v_last),
    'matched_n', (SELECT count(*) FROM _bd WHERE grp IS NOT NULL AND grp <> 'partial'), 'matched_sum', (SELECT coalesce(sum(amt), 0) FROM _bd WHERE grp IS NOT NULL AND grp <> 'partial'),
    'partial_n', (SELECT count(*) FROM _bd WHERE grp = 'partial'), 'partial_sum', (SELECT coalesce(sum(amt), 0) FROM _bd WHERE grp = 'partial'),
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
    'partial', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'date', b.dt, 'amount', b.amt, 'got', s.got, 'gap', round(b.amt - s.got, 2), 'refs', s.refs,
                    'maybe', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.invoice_number, 'date', i.invoice_date, 'balance', i.balance_due,
                                 'who', (SELECT display_name FROM customers WHERE id = (SELECT customer_id FROM locations WHERE id = i.location_id)))), '[]')
                              FROM (SELECT * FROM invoices i WHERE i.bill_to_partner_id = p_partner AND i.status NOT IN ('void', 'draft') AND abs(i.balance_due - (b.amt - s.got)) < 0.01
                                    AND i.invoice_date <= b.dt ORDER BY i.invoice_date DESC LIMIT 4) i)) ORDER BY b.dt DESC), '[]')
                 FROM _bd b CROSS JOIN LATERAL (SELECT sum(a.amt) AS got, string_agg(coalesce(a.refs, a.k), ' + ') AS refs FROM _ag a WHERE a.bank = b.id) s WHERE b.grp = 'partial'),
    'matched', (SELECT coalesce(jsonb_agg(jsonb_build_object('date', b.dt, 'amount', b.amt, 'how', b.grp,
                    'refs', (SELECT string_agg(coalesce(a.refs, a.k), ' + ') FROM _ag a WHERE a.bank = b.id), 'n', (SELECT sum(a.n) FROM _ag a WHERE a.bank = b.id)) ORDER BY b.dt DESC), '[]')
                FROM (SELECT * FROM _bd WHERE grp IS NOT NULL AND grp <> 'partial' ORDER BY dt DESC LIMIT 400) b)) INTO r;
  RETURN r;
END $f$;


NOTIFY pgrst, 'reload schema';

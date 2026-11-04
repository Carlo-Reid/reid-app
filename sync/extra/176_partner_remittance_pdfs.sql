-- Bank: a partner's Remittance Advice PDF (Vista Credit's "Remittance Advice R12775") loaded on the Bank page, like the card statements.
-- Each remittance lists the invoices one payment covered. It is tied to that payment's deposit in the bank (same amount, on or a few days
-- after the payment date; or two remittances paid in one deposit), and the deposit gets exactly those invoices, in place of a guess.
CREATE TABLE IF NOT EXISTS public.partner_remit_docs (
  id bigserial PRIMARY KEY, partner_id bigint, payer text, reference text NOT NULL, pay_date date NOT NULL, total numeric(14,2) NOT NULL,
  file_name text, pdf text, bank_id bigint REFERENCES public.bank_transactions(id) ON DELETE SET NULL, how text,
  loaded_at timestamptz NOT NULL DEFAULT now(), loaded_by bigint, UNIQUE (partner_id, reference));
CREATE TABLE IF NOT EXISTS public.partner_remit_doc_lines (
  id bigserial PRIMARY KEY, doc_id bigint NOT NULL REFERENCES public.partner_remit_docs(id) ON DELETE CASCADE,
  doc_type text, ref_no text, memo text, doc_date date, inv_amount numeric(14,2), paid numeric(14,2), invoice_id bigint);
CREATE INDEX IF NOT EXISTS partner_remit_doc_lines_doc ON public.partner_remit_doc_lines (doc_id);
CREATE INDEX IF NOT EXISTS partner_remit_doc_lines_inv ON public.partner_remit_doc_lines (invoice_id);
CREATE INDEX IF NOT EXISTS partner_remit_docs_bank ON public.partner_remit_docs (bank_id);
CREATE INDEX IF NOT EXISTS invoices_invoice_number ON public.invoices (invoice_number);
ALTER TABLE public.partner_remit_docs ENABLE ROW LEVEL SECURITY; ALTER TABLE public.partner_remit_doc_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.partner_remit_docs, public.partner_remit_doc_lines FROM PUBLIC, anon, authenticated;

-- the words a partner's deposits start with in the bank (the same rule the partner matching uses)
CREATE OR REPLACE FUNCTION public._partner_bank_pat(p_partner bigint) RETURNS text LANGUAGE sql STABLE SET search_path TO 'public' AS $f$
  SELECT CASE WHEN name ~* 'vista' THEN 'VISTACREDIT' WHEN name ~* 'costco' THEN 'COSTCO' WHEN name ~* 'rona' THEN 'RONA INC' WHEN name ~* 'lowe' THEN 'LOWE' ELSE upper(split_part(name, ' ', 1)) END
  FROM partners WHERE id = p_partner $f$;

-- tie every loaded remittance of one partner to the bank, and their lines to the invoices (worked out fresh each time)
CREATE OR REPLACE FUNCTION public.partner_remit_match(p_partner bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off' AS $f$
DECLARE pat text := public._partner_bank_pat(p_partner); d record; dep bigint; o record; fname text;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  -- start over for this partner
  DELETE FROM bank_invoice_links k USING partner_remit_docs r WHERE r.partner_id IS NOT DISTINCT FROM p_partner AND k.bank_id = r.bank_id AND k.how = 'remittance pdf';
  DELETE FROM bank_files f USING partner_remit_docs r WHERE r.partner_id IS NOT DISTINCT FROM p_partner AND f.bank_id = r.bank_id AND f.name LIKE 'Remittance %';
  UPDATE partner_remit_docs SET bank_id = NULL, how = NULL WHERE partner_id IS NOT DISTINCT FROM p_partner;
  -- each line's invoice, by its number (ServiceTitan's invoice #)
  UPDATE partner_remit_doc_lines l SET invoice_id = (SELECT i.id FROM invoices i WHERE i.invoice_number = l.ref_no OR i.st_id::text = l.ref_no
      ORDER BY (i.invoice_number = l.ref_no) DESC, (i.status = 'void'), i.id LIMIT 1)
    FROM partner_remit_docs r WHERE r.id = l.doc_id AND r.partner_id IS NOT DISTINCT FROM p_partner;
  IF pat IS NULL THEN RETURN jsonb_build_object('docs', 0); END IF;
  -- 1: one remittance = one deposit (same amount, the payment day or up to 10 days after)
  FOR d IN SELECT * FROM partner_remit_docs WHERE partner_id = p_partner AND total > 0 ORDER BY pay_date, id LOOP
    SELECT t.id INTO dep FROM bank_transactions t WHERE t.amount_in = d.total AND t.description ILIKE pat || '%' AND t.txn_date BETWEEN d.pay_date - 3 AND d.pay_date + 10
      AND NOT EXISTS (SELECT 1 FROM partner_remit_docs x WHERE x.bank_id = t.id) ORDER BY abs(t.txn_date - d.pay_date), t.id LIMIT 1;
    IF dep IS NOT NULL THEN UPDATE partner_remit_docs SET bank_id = dep, how = 'one' WHERE id = d.id; END IF;
  END LOOP;
  -- 2: two remittances paid in one deposit
  FOR d IN SELECT * FROM partner_remit_docs WHERE partner_id = p_partner AND bank_id IS NULL AND total > 0 ORDER BY pay_date, id LOOP
    CONTINUE WHEN (SELECT bank_id FROM partner_remit_docs WHERE id = d.id) IS NOT NULL;
    SELECT x.id AS oid, t.id AS bid INTO o FROM partner_remit_docs x JOIN bank_transactions t ON t.amount_in = d.total + x.total AND t.description ILIKE pat || '%'
        AND t.txn_date BETWEEN greatest(d.pay_date, x.pay_date) - 3 AND least(d.pay_date, x.pay_date) + 10
      WHERE x.partner_id = p_partner AND x.id <> d.id AND x.bank_id IS NULL AND x.total > 0 AND abs(x.pay_date - d.pay_date) <= 5
        AND NOT EXISTS (SELECT 1 FROM partner_remit_docs y WHERE y.bank_id = t.id)
      ORDER BY abs(t.txn_date - d.pay_date), t.id LIMIT 1;
    IF o.bid IS NOT NULL THEN UPDATE partner_remit_docs SET bank_id = o.bid, how = 'two' WHERE id IN (d.id, o.oid); END IF;
  END LOOP;
  -- 3: each deposit gets exactly the remittance's invoices (in place of the partner guess; ties made by hand stay), the PDF and a note
  FOR d IN SELECT bank_id, array_agg(id) AS ids, string_agg(reference, ' + ' ORDER BY reference) AS refs FROM partner_remit_docs WHERE partner_id = p_partner AND bank_id IS NOT NULL GROUP BY bank_id LOOP
    DELETE FROM bank_invoice_links WHERE bank_id = d.bank_id AND coalesce(how, '') <> 'by hand';
    INSERT INTO bank_invoice_links (bank_id, invoice_id, amount, partner_id, how)
      SELECT d.bank_id, l.invoice_id, sum(l.paid), NULL, 'remittance pdf' FROM partner_remit_doc_lines l WHERE l.doc_id = ANY (d.ids) AND l.invoice_id IS NOT NULL GROUP BY l.invoice_id
      ON CONFLICT (bank_id, invoice_id) DO NOTHING;
    INSERT INTO bank_files (bank_id, name, mime, data, size)
      SELECT d.bank_id, 'Remittance ' || r.reference || '.pdf', 'application/pdf', r.pdf, (length(r.pdf) * 3 / 4)::int FROM partner_remit_docs r WHERE r.id = ANY (d.ids) AND r.pdf IS NOT NULL;
    UPDATE bank_transactions SET note = coalesce(nullif(note, ''), (SELECT name FROM partners WHERE id = p_partner) || ' remittance ' || d.refs) WHERE id = d.bank_id;
  END LOOP;
  RETURN jsonb_build_object('docs', (SELECT count(*) FROM partner_remit_docs WHERE partner_id = p_partner),
    'in_bank', (SELECT count(*) FROM partner_remit_docs WHERE partner_id = p_partner AND bank_id IS NOT NULL));
END $f$;

-- save one remittance read from the PDF in the browser (replaces the same partner's same remittance #), then match
CREATE OR REPLACE FUNCTION public.partner_remit_save(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v bigint; pid bigint; x jsonb; m jsonb; r partner_remit_docs;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  IF nullif(p ->> 'reference', '') IS NULL OR (p ->> 'pay_date') IS NULL THEN RAISE EXCEPTION 'Couldn''t read the remittance # or the payment date'; END IF;
  IF jsonb_typeof(p -> 'lines') <> 'array' OR jsonb_array_length(p -> 'lines') = 0 THEN RAISE EXCEPTION 'No invoices found on the remittance'; END IF;
  SELECT id INTO pid FROM partners WHERE name ~* coalesce(nullif(p ->> 'payer', ''), '^$') ORDER BY id LIMIT 1;
  DELETE FROM partner_remit_docs WHERE partner_id IS NOT DISTINCT FROM pid AND reference = p ->> 'reference';
  INSERT INTO partner_remit_docs (partner_id, payer, reference, pay_date, total, file_name, pdf, loaded_by)
  VALUES (pid, p ->> 'payer', p ->> 'reference', (p ->> 'pay_date')::date, (p ->> 'total')::numeric, p ->> 'file_name', p ->> 'pdf', public.current_app_user_id()) RETURNING id INTO v;
  FOR x IN SELECT * FROM jsonb_array_elements(p -> 'lines') LOOP
    INSERT INTO partner_remit_doc_lines (doc_id, doc_type, ref_no, memo, doc_date, inv_amount, paid)
    VALUES (v, x ->> 'doc_type', x ->> 'ref_no', x ->> 'memo', (x ->> 'doc_date')::date, (x ->> 'inv_amount')::numeric, (x ->> 'paid')::numeric);
  END LOOP;
  m := public.partner_remit_match(pid);
  SELECT * INTO r FROM partner_remit_docs WHERE id = v;
  RETURN jsonb_build_object('id', v, 'partner', (SELECT name FROM partners WHERE id = pid), 'bank_id', r.bank_id, 'how', r.how,
    'bank_date', (SELECT txn_date FROM bank_transactions WHERE id = r.bank_id), 'bank_amount', (SELECT amount_in FROM bank_transactions WHERE id = r.bank_id),
    'lines', (SELECT count(*) FROM partner_remit_doc_lines WHERE doc_id = v), 'found', (SELECT count(*) FROM partner_remit_doc_lines WHERE doc_id = v AND invoice_id IS NOT NULL),
    'owing', (SELECT count(*) FROM partner_remit_doc_lines l JOIN invoices i ON i.id = l.invoice_id WHERE l.doc_id = v AND i.balance_due > 0.004));
END $f$;

CREATE OR REPLACE FUNCTION public.partner_remit_delete(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE pid bigint;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  SELECT partner_id INTO pid FROM partner_remit_docs WHERE id = p_id;
  DELETE FROM bank_invoice_links k USING partner_remit_docs r WHERE r.id = p_id AND k.bank_id = r.bank_id AND k.how = 'remittance pdf';
  DELETE FROM bank_files f USING partner_remit_docs r WHERE r.id = p_id AND f.bank_id = r.bank_id AND f.name = 'Remittance ' || r.reference || '.pdf';
  DELETE FROM partner_remit_docs WHERE id = p_id;
  PERFORM public.partner_remit_match(pid);
END $f$;

CREATE OR REPLACE FUNCTION public.partner_remit_pdf(p_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._bank_owner() THEN (SELECT jsonb_build_object('b64', pdf, 'name', coalesce(file_name, 'Remittance ' || reference || '.pdf'), 'mime', 'application/pdf') FROM partner_remit_docs WHERE id = p_id) END $f$;

CREATE OR REPLACE FUNCTION public.partner_remit_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._bank_owner() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object(
      'id', r.id, 'partner', coalesce(pt.name, r.payer), 'reference', r.reference, 'date', r.pay_date, 'total', r.total, 'file', r.file_name, 'how', r.how,
      'bank', CASE WHEN b.id IS NOT NULL THEN jsonb_build_object('id', b.id, 'date', b.txn_date, 'amount', b.amount_in, 'account', b.account, 'description', b.description) END,
      'with', (SELECT string_agg(o.reference, ', ') FROM partner_remit_docs o WHERE o.bank_id = r.bank_id AND o.id <> r.id),
      'lines', (SELECT coalesce(jsonb_agg(jsonb_build_object('type', l.doc_type, 'ref', l.ref_no, 'memo', l.memo, 'date', l.doc_date, 'amount', l.inv_amount, 'paid', l.paid,
                  'inv', CASE WHEN i.id IS NOT NULL THEN jsonb_build_object('id', i.id, 'number', i.invoice_number, 'total', i.total, 'balance', i.balance_due, 'status', i.status,
                    'who', coalesce((SELECT display_name FROM customers WHERE id = lo.customer_id), c.display_name), 'street', lo.street) END) ORDER BY l.id), '[]')
                FROM partner_remit_doc_lines l LEFT JOIN invoices i ON i.id = l.invoice_id LEFT JOIN customers c ON c.id = i.customer_id LEFT JOIN locations lo ON lo.id = i.location_id
                WHERE l.doc_id = r.id))
    ORDER BY r.pay_date DESC, r.reference DESC) FROM partner_remit_docs r LEFT JOIN partners pt ON pt.id = r.partner_id LEFT JOIN bank_transactions b ON b.id = r.bank_id), '[]') END $f$;

REVOKE EXECUTE ON FUNCTION public.partner_remit_match(bigint), public.partner_remit_save(jsonb), public.partner_remit_delete(bigint), public.partner_remit_pdf(bigint), public.partner_remit_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.partner_remit_match(bigint), public.partner_remit_save(jsonb), public.partner_remit_delete(bigint), public.partner_remit_pdf(bigint), public.partner_remit_list() TO authenticated;

-- the partner guesser leaves alone the deposits a remittance PDF has placed, and the app's payments for those invoices
DO $do$
DECLARE src text := pg_get_functiondef('public.bank_partner_match(bigint)'::regprocedure);
BEGIN
  IF src LIKE '%partner_remit_docs%' THEN RETURN; END IF;
  src := replace(src, $a$  INSERT INTO _bd SELECT id, txn_date, amount_in, NULL FROM bank_transactions WHERE amount_in > 0 AND description ILIKE pat || '%';$a$,
                      $a$  INSERT INTO _bd SELECT id, txn_date, amount_in, NULL FROM bank_transactions WHERE amount_in > 0 AND description ILIKE pat || '%'
    AND id NOT IN (SELECT bank_id FROM partner_remit_docs WHERE bank_id IS NOT NULL);$a$);
  src := replace(src, $a$  INSERT INTO _pid SELECT id FROM payments WHERE method = 'partner_remittance' AND notes ILIKE word || '%' ON CONFLICT DO NOTHING;$a$,
                      $a$  INSERT INTO _pid SELECT id FROM payments WHERE method = 'partner_remittance' AND notes ILIKE word || '%' ON CONFLICT DO NOTHING;
  DELETE FROM _pid WHERE id IN (SELECT pa.payment_id FROM partner_remit_docs r JOIN partner_remit_doc_lines l ON l.doc_id = r.id JOIN payment_applications pa ON pa.invoice_id = l.invoice_id
    JOIN payments py ON py.id = pa.payment_id WHERE r.bank_id IS NOT NULL AND py.received_on BETWEEN r.pay_date - 60 AND r.pay_date + 15);$a$);
  IF src NOT LIKE '%partner_remit_docs WHERE bank_id%' OR src NOT LIKE '%DELETE FROM _pid%' THEN RAISE EXCEPTION 'bank_partner_match: anchor not found'; END IF;
  EXECUTE src;
END $do$;
NOTIFY pgrst, 'reload schema';

-- Receivables: "payments in the bank with no invoice" (Carlo, Nov 9). Money that came into the bank (deposits, card and online payments,
-- partners and financing, other) with nothing attached to it on the Bank page. Receivables staff see the list and link an invoice to a payment;
-- the link is a bank_invoice_links row, the same one the Bank page makes, so it shows on the Bank page right away.
CREATE OR REPLACE FUNCTION public._recv_ok() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(public.has_permission('invoices.adjust') OR public.current_staff_role() IN ('owner', 'admin', 'accounting') OR public._bank_owner(), false) $f$;

DROP FUNCTION IF EXISTS public.bank_unapplied(integer, integer, integer);
CREATE OR REPLACE FUNCTION public.bank_unapplied(p_year integer DEFAULT NULL, p_limit integer DEFAULT 25, p_offset integer DEFAULT 0, p_month text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r jsonb;
BEGIN
  IF NOT public._recv_ok() THEN RAISE EXCEPTION 'You don''t have permission to see this list'; END IF;
  WITH f AS (
    SELECT b.id, b.txn_date, b.account, b.description, b.amount_in, b.note FROM bank_transactions b
    WHERE b.amount_in > 0 AND b.txn_date >= DATE '2026-01-01'   -- only 2026 and forward (Carlo, Nov 9)
      AND public._bank_cat(b.description, b.code, b.amount_in) IN ('Deposits', 'Card & online payments in', 'Partners & financing', 'Other')
      AND NOT EXISTS (SELECT 1 FROM bank_invoice_links k WHERE k.bank_id = b.id) AND NOT EXISTS (SELECT 1 FROM bank_files k WHERE k.bank_id = b.id)
      AND NOT EXISTS (SELECT 1 FROM bank_sinv_links k WHERE k.bank_id = b.id) AND NOT EXISTS (SELECT 1 FROM bank_transfer_links k WHERE k.a_id = b.id OR k.b_id = b.id)
      AND NOT EXISTS (SELECT 1 FROM bank_vehicle_links k WHERE k.bank_id = b.id)),
  g AS (SELECT * FROM f WHERE (p_year IS NULL OR extract(year FROM txn_date) = p_year) AND (p_month IS NULL OR to_char(txn_date, 'YYYY-MM') = p_month)),
  pg AS (SELECT * FROM g ORDER BY txn_date DESC, id DESC LIMIT least(greatest(coalesce(p_limit, 25), 1), 200) OFFSET greatest(coalesce(p_offset, 0), 0)),
  cand AS (   -- invoices for exactly the same amount, dated up to 4 months before the money came in, whose money is not found in the bank yet
    SELECT pg.id AS bank_id, i.id, i.invoice_number, i.invoice_date, i.total, i.balance_due, c.display_name,
           row_number() OVER (PARTITION BY pg.id ORDER BY abs(pg.txn_date - i.invoice_date), i.id DESC) AS rn
    FROM pg JOIN invoices i ON i.total = pg.amount_in AND i.status <> 'void' AND i.invoice_date BETWEEN pg.txn_date - 120 AND pg.txn_date + 7
      LEFT JOIN customers c ON c.id = i.customer_id
    WHERE NOT EXISTS (SELECT 1 FROM bank_invoice_links k WHERE k.invoice_id = i.id))
  SELECT jsonb_build_object(
    'count', (SELECT count(*) FROM g), 'sum', (SELECT coalesce(sum(amount_in), 0) FROM g), 'all', (SELECT count(*) FROM f),
    'years', (SELECT coalesce(jsonb_agg(jsonb_build_object('y', y, 'n', n, 'sum', s) ORDER BY y DESC), '[]'::jsonb) FROM (SELECT extract(year FROM txn_date)::int y, count(*) n, sum(amount_in) s FROM f GROUP BY 1) t),
    'months', (SELECT coalesce(jsonb_agg(jsonb_build_object('m', m, 'n', n, 'sum', s) ORDER BY m DESC), '[]'::jsonb) FROM (SELECT to_char(txn_date, 'YYYY-MM') m, count(*) n, sum(amount_in) s FROM f GROUP BY 1) t),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', pg.id, 'date', pg.txn_date, 'account', pg.account, 'description', pg.description, 'amount', pg.amount_in, 'note', pg.note,
        'cands', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', cd.id, 'number', cd.invoice_number, 'date', cd.invoice_date, 'total', cd.total, 'balance', cd.balance_due, 'customer', cd.display_name) ORDER BY cd.rn), '[]'::jsonb)
                  FROM cand cd WHERE cd.bank_id = pg.id AND cd.rn <= 3)) ORDER BY pg.txn_date DESC, pg.id DESC), '[]'::jsonb) FROM pg)) INTO r;
  RETURN r;
END $function$;

CREATE OR REPLACE FUNCTION public.bank_unapplied_link(p_bank bigint, p_number text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE n text := btrim(regexp_replace(coalesce(p_number, ''), '^#', '')); v invoices; b bank_transactions; left_amt numeric;
BEGIN
  IF NOT public._recv_ok() THEN RAISE EXCEPTION 'You don''t have permission to link payments'; END IF;
  SELECT * INTO b FROM bank_transactions WHERE id = p_bank; IF b.id IS NULL OR coalesce(b.amount_in, 0) <= 0 THEN RAISE EXCEPTION 'That payment is not in the bank list any more'; END IF;
  IF n = '' THEN RAISE EXCEPTION 'Type the invoice number'; END IF;
  SELECT * INTO v FROM invoices WHERE invoice_number = n AND status <> 'void' ORDER BY id DESC LIMIT 1;
  IF v.id IS NULL THEN RAISE EXCEPTION 'I can''t find invoice % in the app. Check the number.', n; END IF;
  IF EXISTS (SELECT 1 FROM bank_invoice_links WHERE bank_id = p_bank AND invoice_id = v.id) THEN RAISE EXCEPTION 'Invoice % is already linked to this payment', n; END IF;
  left_amt := b.amount_in - coalesce((SELECT sum(amount) FROM bank_invoice_links WHERE bank_id = p_bank), 0);
  INSERT INTO bank_invoice_links (bank_id, invoice_id, amount, partner_id, how, made_by)
  VALUES (p_bank, v.id, least(v.total, greatest(left_amt, 0)), NULL, 'by hand', public.current_app_user_id());
  RETURN jsonb_build_object('invoice_id', v.id, 'number', v.invoice_number, 'total', v.total, 'date', v.invoice_date,
    'customer', (SELECT display_name FROM customers WHERE id = v.customer_id),
    'linked', (SELECT sum(amount) FROM bank_invoice_links WHERE bank_id = p_bank), 'amount', b.amount_in);
END $function$;

-- Undo a link made by hand (a slip of the finger on the Receivables list)
CREATE OR REPLACE FUNCTION public.bank_unapplied_unlink(p_bank bigint, p_invoice bigint)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public._recv_ok() THEN RAISE EXCEPTION 'You don''t have permission to change this'; END IF;
  DELETE FROM bank_invoice_links WHERE bank_id = p_bank AND invoice_id = p_invoice AND how = 'by hand'
    AND (made_by = public.current_app_user_id() OR public._bank_owner());
  IF NOT FOUND THEN RAISE EXCEPTION 'Only the person who made this link, or an owner, can take it off'; END IF;
END $function$;

REVOKE EXECUTE ON FUNCTION public.bank_unapplied(integer, integer, integer, text), public.bank_unapplied_link(bigint, text), public.bank_unapplied_unlink(bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bank_unapplied(integer, integer, integer, text), public.bank_unapplied_link(bigint, text), public.bank_unapplied_unlink(bigint, bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

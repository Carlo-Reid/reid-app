-- Bank: attach to a bank line by hand: one of our invoices, a supplier's invoice (by its number), or a file (a bill, receipt, statement…)
CREATE TABLE IF NOT EXISTS public.bank_sinv_links (
  bank_id bigint NOT NULL REFERENCES public.bank_transactions(id) ON DELETE CASCADE,
  supplier_invoice_id bigint NOT NULL, made_at timestamptz NOT NULL DEFAULT now(), made_by bigint,
  PRIMARY KEY (bank_id, supplier_invoice_id));
CREATE TABLE IF NOT EXISTS public.bank_files (
  id bigserial PRIMARY KEY, bank_id bigint NOT NULL REFERENCES public.bank_transactions(id) ON DELETE CASCADE,
  name text, mime text, data text NOT NULL, size int, added_by bigint, added_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS bank_files_bank ON public.bank_files (bank_id);
ALTER TABLE public.bank_sinv_links ENABLE ROW LEVEL SECURITY; ALTER TABLE public.bank_files ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.bank_sinv_links, public.bank_files FROM PUBLIC, anon, authenticated;
ALTER TABLE public.bank_invoice_links ADD COLUMN IF NOT EXISTS made_by bigint;

-- tie a number: our invoice first, then a supplier's invoice with that number
CREATE OR REPLACE FUNCTION public.bank_attach_number(p_bank bigint, p_number text, p_amount numeric DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n text := btrim(regexp_replace(coalesce(p_number, ''), '^#', '')); v_inv invoices; v_si bigint; v_cnt int; b bank_transactions;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  SELECT * INTO b FROM bank_transactions WHERE id = p_bank; IF b.id IS NULL THEN RAISE EXCEPTION 'That bank line is gone'; END IF;
  IF n = '' THEN RAISE EXCEPTION 'Type an invoice number'; END IF;
  SELECT * INTO v_inv FROM invoices WHERE invoice_number = n AND status <> 'void' ORDER BY id DESC LIMIT 1;
  IF v_inv.id IS NOT NULL THEN
    INSERT INTO bank_invoice_links (bank_id, invoice_id, amount, partner_id, how, made_by)
    VALUES (p_bank, v_inv.id, coalesce(p_amount, least(v_inv.total, greatest(b.amount_in, b.amount_out))), NULL, 'by hand', public.current_app_user_id())
    ON CONFLICT (bank_id, invoice_id) DO UPDATE SET amount = EXCLUDED.amount, how = 'by hand', made_by = EXCLUDED.made_by;
    RETURN jsonb_build_object('kind', 'invoice', 'number', v_inv.invoice_number);
  END IF;
  SELECT count(*), min(id) INTO v_cnt, v_si FROM supplier_invoices WHERE upper(supplier_invoice_number) = upper(n);
  IF v_cnt = 0 THEN RAISE EXCEPTION 'No invoice or supplier invoice # % in the app', n; END IF;
  INSERT INTO bank_sinv_links (bank_id, supplier_invoice_id, made_by) SELECT p_bank, id, public.current_app_user_id() FROM supplier_invoices WHERE upper(supplier_invoice_number) = upper(n)
    ON CONFLICT DO NOTHING;
  RETURN jsonb_build_object('kind', 'supplier_invoice', 'number', n, 'count', v_cnt);
END $f$;

CREATE OR REPLACE FUNCTION public.bank_detach(p_bank bigint, p_kind text, p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  IF p_kind = 'invoice' THEN DELETE FROM bank_invoice_links WHERE bank_id = p_bank AND invoice_id = p_id;
  ELSIF p_kind = 'sinv' THEN DELETE FROM bank_sinv_links WHERE bank_id = p_bank AND supplier_invoice_id = p_id;
  ELSIF p_kind = 'file' THEN DELETE FROM bank_files WHERE bank_id = p_bank AND id = p_id; END IF;
END $f$;

CREATE OR REPLACE FUNCTION public.bank_file_add(p_bank bigint, p_name text, p_mime text, p_b64 text) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v bigint;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  IF length(p_b64) > 14000000 THEN RAISE EXCEPTION 'That file is too big (10 MB at most)'; END IF;
  INSERT INTO bank_files (bank_id, name, mime, data, size, added_by) VALUES (p_bank, p_name, p_mime, p_b64, (length(p_b64) * 3 / 4)::int, public.current_app_user_id()) RETURNING id INTO v;
  RETURN v;
END $f$;
CREATE OR REPLACE FUNCTION public.bank_file_get(p_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._bank_owner() THEN (SELECT jsonb_build_object('name', name, 'mime', mime, 'b64', data) FROM bank_files WHERE id = p_id) END $f$;

-- what's attached to a line (supplier invoices and files), for the lists
CREATE OR REPLACE FUNCTION public._bank_att(p_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT jsonb_build_object(
    'sinv', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', si.id, 'number', si.supplier_invoice_number, 'supplier', btrim(sp.name), 'date', si.invoice_date, 'total', si.total) ORDER BY si.invoice_date), '[]')
             FROM bank_sinv_links k JOIN supplier_invoices si ON si.id = k.supplier_invoice_id JOIN suppliers sp ON sp.id = si.supplier_id WHERE k.bank_id = p_id),
    'files', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'size', f.size) ORDER BY f.id), '[]') FROM bank_files f WHERE f.bank_id = p_id)) $f$;

REVOKE EXECUTE ON FUNCTION public.bank_attach_number(bigint, text, numeric), public.bank_detach(bigint, text, bigint), public.bank_file_add(bigint, text, text, text), public.bank_file_get(bigint), public._bank_att(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bank_attach_number(bigint, text, numeric), public.bank_detach(bigint, text, bigint), public.bank_file_add(bigint, text, text, text), public.bank_file_get(bigint) TO authenticated;

DO $do$
DECLARE s1 text := pg_get_functiondef('public.bank_list(text, date, date, text, text, int, int, text)'::regprocedure);
        s2 text := pg_get_functiondef('public.bank_ledger(text, text, date, date, boolean, int, int)'::regprocedure);
BEGIN
  IF s1 NOT LIKE '%_bank_att%' THEN
    s1 := replace(s1, $a$'transfer', public._bank_xfer(x.id),$a$, $a$'transfer', public._bank_xfer(x.id), 'att', public._bank_att(x.id),$a$);
    s1 := replace(s1, $a$'invoices', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.invoice_number, 'date', i.invoice_date, 'amount', k.amount,$a$,
                      $a$'invoices', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.invoice_number, 'date', i.invoice_date, 'amount', k.amount, 'how', k.how,$a$);
    IF s1 NOT LIKE '%_bank_att%' THEN RAISE EXCEPTION 'bank_list: anchor not found'; END IF; EXECUTE s1; END IF;
  IF s2 NOT LIKE '%_bank_att%' THEN
    s2 := replace(s2, $a$'transfer', public._bank_xfer(x.id),$a$, $a$'transfer', public._bank_xfer(x.id), 'att', public._bank_att(x.id),$a$);
    s2 := replace(s2, $a$OR EXISTS (SELECT 1 FROM bank_transfer_links t WHERE b.id IN (t.a_id, t.b_id)))$a$,
                      $a$OR EXISTS (SELECT 1 FROM bank_transfer_links t WHERE b.id IN (t.a_id, t.b_id)) OR EXISTS (SELECT 1 FROM bank_sinv_links s WHERE s.bank_id = b.id) OR EXISTS (SELECT 1 FROM bank_files f WHERE f.bank_id = b.id))$a$);
    IF s2 NOT LIKE '%_bank_att%' OR s2 NOT LIKE '%bank_files f WHERE f.bank_id = b.id%' THEN RAISE EXCEPTION 'bank_ledger: anchor not found'; END IF; EXECUTE s2; END IF;
END $do$;
NOTIFY pgrst, 'reload schema';

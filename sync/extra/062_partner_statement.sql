-- Partner payment history (Costco's PAYMENTHISTORY download): every line kept as Costco sends it,
-- then each Costco invoice is connected to our invoice / customer (automatically where the numbers fit, or by hand).
CREATE TABLE IF NOT EXISTS public.partner_statement_lines (
  id bigserial PRIMARY KEY,
  partner_id bigint NOT NULL,
  doc_no text NOT NULL,            -- the partner's invoice number
  doc_date date,
  amount numeric(12,2) NOT NULL,   -- Invoice Total (the fee comes as its own negative line)
  discount numeric(12,2) NOT NULL DEFAULT 0,
  net numeric(12,2) NOT NULL,
  payment_no text NOT NULL DEFAULT '',
  payment_date date,
  po_no text,
  ra_no text,
  gst numeric(12,2) NOT NULL DEFAULT 0,
  hst numeric(12,2) NOT NULL DEFAULT 0,
  qst numeric(12,2) NOT NULL DEFAULT 0,
  imported_at timestamptz NOT NULL DEFAULT now(),
  imported_by bigint
);
CREATE UNIQUE INDEX IF NOT EXISTS partner_statement_lines_uq ON public.partner_statement_lines (partner_id, doc_no, payment_no, amount);
CREATE INDEX IF NOT EXISTS partner_statement_lines_doc ON public.partner_statement_lines (partner_id, doc_no);

CREATE TABLE IF NOT EXISTS public.partner_statement_matches (
  partner_id bigint NOT NULL,
  doc_no text NOT NULL,
  invoice_id bigint,               -- null = looked at, nothing of ours
  how text NOT NULL DEFAULT 'auto', -- auto | guess | hand
  matched_by bigint,
  matched_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (partner_id, doc_no)
);
ALTER TABLE public.partner_statement_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partner_statement_matches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.partner_statement_lines, public.partner_statement_matches FROM PUBLIC, anon, authenticated;

-- p_rows: [{doc_no, doc_date, amount, discount, net, payment_no, payment_date, po_no, ra_no, gst, hst, qst}]
CREATE OR REPLACE FUNCTION public.partner_statement_import(p_partner bigint, p_rows jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_new int; v_all int;
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'You don''t have permission to change partner payments'; END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'Nothing to load'; END IF;
  v_all := jsonb_array_length(p_rows);
  WITH r AS (
    SELECT btrim(x->>'doc_no') doc_no, nullif(x->>'doc_date','')::date doc_date, (x->>'amount')::numeric amount, coalesce(nullif(x->>'discount','')::numeric,0) discount,
           coalesce(nullif(x->>'net','')::numeric, (x->>'amount')::numeric) net, coalesce(btrim(x->>'payment_no'),'') payment_no, nullif(x->>'payment_date','')::date payment_date,
           nullif(btrim(x->>'po_no'),'') po_no, nullif(btrim(x->>'ra_no'),'') ra_no,
           coalesce(nullif(x->>'gst','')::numeric,0) gst, coalesce(nullif(x->>'hst','')::numeric,0) hst, coalesce(nullif(x->>'qst','')::numeric,0) qst
    FROM jsonb_array_elements(p_rows) x WHERE coalesce(btrim(x->>'doc_no'),'') <> '' AND x->>'amount' IS NOT NULL),
  ins AS (
    INSERT INTO partner_statement_lines (partner_id, doc_no, doc_date, amount, discount, net, payment_no, payment_date, po_no, ra_no, gst, hst, qst, imported_by)
    SELECT p_partner, doc_no, doc_date, amount, discount, net, payment_no, payment_date, po_no, ra_no, gst, hst, qst, public.current_app_user_id() FROM r
    ON CONFLICT (partner_id, doc_no, payment_no, amount) DO NOTHING RETURNING 1)
  SELECT count(*) INTO v_new FROM ins;
  RETURN jsonb_build_object('rows', v_all, 'new', v_new, 'matched', public.partner_statement_match(p_partner));
END $function$;

-- connect each partner invoice to ours: Costco pays 89% or 90% of our price before tax (sometimes 100%),
-- and its invoice comes a few days to a few weeks after ours. Hand matches are never touched.
CREATE OR REPLACE FUNCTION public.partner_statement_match(p_partner bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE g record; v_id bigint; v_gap int; v_n int := 0; v_cnt int; v_pname text; v_pcust bigint;
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'You don''t have permission to change partner payments'; END IF;
  DELETE FROM partner_statement_matches WHERE partner_id = p_partner AND how IN ('auto','guess');   -- worked out fresh each time; hand matches stay
  SELECT name INTO v_pname FROM partners WHERE id = p_partner;
  SELECT customer_account_id INTO v_pcust FROM partners WHERE id = p_partner;
  FOR g IN
    SELECT l.doc_no, min(l.doc_date) doc_date, sum(l.amount) FILTER (WHERE l.amount > 0) sale, sum(l.hst + l.gst + l.qst) FILTER (WHERE l.amount > 0) tax, sum(l.net) net
    FROM partner_statement_lines l
    WHERE l.partner_id = p_partner AND NOT EXISTS (SELECT 1 FROM partner_statement_matches m WHERE m.partner_id = p_partner AND m.doc_no = l.doc_no)
    GROUP BY l.doc_no HAVING sum(l.amount) FILTER (WHERE l.amount > 0) > 0 ORDER BY min(l.doc_date), l.doc_no
  LOOP
    WITH cand AS (
      SELECT i.id, i.invoice_date, abs(g.doc_date - i.invoice_date) + CASE WHEN i.invoice_date > g.doc_date THEN 30 ELSE 0 END AS dist
      FROM invoices i LEFT JOIN jobs j ON j.id = i.job_id
      WHERE (j.partner_id = p_partner OR i.bill_to_partner_id = p_partner OR v_pcust IN (j.customer_id, i.customer_id)
             OR EXISTS (SELECT 1 FROM customers pc WHERE pc.id IN (j.customer_id, i.customer_id) AND pc.display_name ILIKE v_pname || '%'))   -- billed to "Costco Inc."
        AND i.subtotal > 0
        AND i.invoice_date BETWEEN g.doc_date - 75 AND g.doc_date + 7
        AND (abs((g.sale - g.tax) - round(i.subtotal * 0.89, 2)) <= 0.02 OR abs((g.sale - g.tax) - round(i.subtotal * 0.90, 2)) <= 0.02 OR abs((g.sale - g.tax) - i.subtotal) <= 0.02
             -- older invoices typed in at what the store paid, or at the store's own total
             OR abs(i.total - g.net) <= 0.02 OR abs(i.total - g.sale) <= 0.02 OR abs(coalesce(i.amount_paid, 0) - g.net) <= 0.02)
        AND NOT EXISTS (SELECT 1 FROM partner_statement_matches m WHERE m.partner_id = p_partner AND m.invoice_id = i.id))
    SELECT count(*) OVER (), id, dist INTO v_cnt, v_id, v_gap FROM cand ORDER BY dist, id LIMIT 1;
    IF v_id IS NOT NULL THEN
      INSERT INTO partner_statement_matches (partner_id, doc_no, invoice_id, how, matched_by) VALUES (p_partner, g.doc_no, v_id, CASE WHEN v_cnt = 1 AND v_gap <= 30 THEN 'auto' ELSE 'guess' END, NULL)
      ON CONFLICT (partner_id, doc_no) DO NOTHING;
      v_n := v_n + 1;
    END IF;
    v_id := NULL;
  END LOOP;
  RETURN v_n;
END $function$;

-- by hand: type our invoice # or job #; blank = take it off
CREATE OR REPLACE FUNCTION public.partner_statement_set(p_partner bigint, p_doc text, p_number text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_inv bigint; v_num text := regexp_replace(coalesce(p_number,''), '[^0-9A-Za-z]', '', 'g');
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'You don''t have permission to change partner payments'; END IF;
  IF v_num = '' THEN DELETE FROM partner_statement_matches WHERE partner_id = p_partner AND doc_no = p_doc; RETURN NULL; END IF;
  SELECT id INTO v_inv FROM invoices WHERE invoice_number = v_num AND subtotal > 0 ORDER BY invoice_date DESC LIMIT 1;
  IF v_inv IS NULL THEN SELECT i.id INTO v_inv FROM invoices i JOIN jobs j ON j.id = i.job_id WHERE j.job_number = v_num ORDER BY i.subtotal DESC, i.invoice_date DESC LIMIT 1; END IF;
  IF v_inv IS NULL THEN RAISE EXCEPTION 'No invoice or job % found', p_number; END IF;
  INSERT INTO partner_statement_matches (partner_id, doc_no, invoice_id, how, matched_by, matched_at) VALUES (p_partner, p_doc, v_inv, 'hand', public.current_app_user_id(), now())
  ON CONFLICT (partner_id, doc_no) DO UPDATE SET invoice_id = EXCLUDED.invoice_id, how = 'hand', matched_by = EXCLUDED.matched_by, matched_at = now();
  RETURN jsonb_build_object('invoice_id', v_inv);
END $function$;

-- the list: one row per partner invoice (sale + fee lines together), with our customer and invoice
CREATE OR REPLACE FUNCTION public.partner_statement_list(p_partner bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'You don''t have permission to see partner payments'; END IF;
  RETURN coalesce((SELECT jsonb_agg(row_to_json(t) ORDER BY t.doc_date DESC, t.doc_no DESC) FROM (
    SELECT g.doc_no, g.doc_date, g.po_no, g.sale, g.tax, g.fee, g.net, g.paid_on, g.payments,
           m.how, i.id invoice_id, i.invoice_number, i.invoice_date, i.subtotal, i.total, i.job_id,
           coalesce(lo.customer_id, j.customer_id, i.customer_id) customer_id, coalesce(lc.display_name, lo.name, cu.display_name) customer_name, lo.street, lo.city,
           CASE WHEN i.subtotal > 0 THEN round((g.sale - g.tax) / i.subtotal * 100, 1) END pct
    FROM (SELECT l.doc_no, min(l.doc_date) doc_date, max(l.po_no) po_no,
                 coalesce(sum(l.amount) FILTER (WHERE l.amount > 0), 0) sale, coalesce(sum(l.hst + l.gst + l.qst) FILTER (WHERE l.amount > 0), 0) tax,
                 coalesce(sum(l.amount) FILTER (WHERE l.amount < 0), 0) fee, sum(l.net) net, max(l.payment_date) paid_on,
                 jsonb_agg(jsonb_build_object('no', l.payment_no, 'date', l.payment_date, 'net', l.net) ORDER BY l.payment_date, l.amount DESC) payments
          FROM partner_statement_lines l WHERE l.partner_id = p_partner GROUP BY l.doc_no) g
    LEFT JOIN partner_statement_matches m ON m.partner_id = p_partner AND m.doc_no = g.doc_no
    LEFT JOIN invoices i ON i.id = m.invoice_id
    LEFT JOIN jobs j ON j.id = i.job_id
    LEFT JOIN locations lo ON lo.id = j.location_id
    LEFT JOIN customers lc ON lc.id = lo.customer_id
    LEFT JOIN customers cu ON cu.id = i.customer_id) t), '[]'::jsonb);
END $function$;

REVOKE EXECUTE ON FUNCTION public.partner_statement_import(bigint, jsonb), public.partner_statement_match(bigint), public.partner_statement_set(bigint, text, text), public.partner_statement_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.partner_statement_import(bigint, jsonb), public.partner_statement_match(bigint), public.partner_statement_set(bigint, text, text), public.partner_statement_list(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

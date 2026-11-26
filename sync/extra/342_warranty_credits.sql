-- Warranty credits (Carlo, Nov 26, 2026: "make it a page in the system"). In ServiceTitan the office tracks Lennox warranty credits on
-- one customer file, "Lennox - Warranty Credit" (customer 17134704): each warranty part is a $0 invoice whose line note says
-- "14K09 paid with lennox credit memo 0610261679 <customer> <address>". This page ties each of those notes to the Lennox credit
-- on file with that number, and lists what is still missing.
-- Groups: tied · matches but not tied (a person took it off) · check (a credit we have is one digit off) · the number looks mistyped ·
-- ask Lennox (not on file) · older than our Lennox credits. Lennox credits tied to nothing are listed too, to tie by hand.
CREATE TABLE IF NOT EXISTS public.warranty_credit_asks (
  memo text NOT NULL, invoice_id bigint NOT NULL, asked_on date NOT NULL DEFAULT current_date, asked_by bigint, PRIMARY KEY (memo, invoice_id));
ALTER TABLE public.warranty_credit_asks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.warranty_credit_asks FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._wc_customer() RETURNS bigint LANGUAGE sql IMMUTABLE AS $f$ SELECT 17134704::bigint $f$;
CREATE OR REPLACE FUNCTION public._wc_supplier() RETURNS bigint LANGUAGE sql IMMUTABLE AS $f$ SELECT 2::bigint $f$;
CREATE OR REPLACE FUNCTION public._wc_key(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT ltrim(regexp_replace(coalesce(t, ''), '\D', '', 'g'), '0') $f$;

-- every credit memo number written in the notes of the warranty customer's invoices
CREATE OR REPLACE FUNCTION public._wc_notes() RETURNS TABLE (invoice_id bigint, num text, k text, k2 text, note text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT DISTINCT ON (i.id, m[1]) i.id, m[1], public._wc_key(m[1]),
    CASE WHEN m[1] ~ '001$' AND length(m[1]) >= 12 THEN public._wc_key(left(m[1], length(m[1]) - 3)) END, l.description
  FROM invoices i JOIN invoice_lines l ON l.invoice_id = i.id
    CROSS JOIN LATERAL regexp_matches(coalesce(l.description, ''), '(\d{8,13})', 'g') m
  WHERE i.customer_id = public._wc_customer() AND i.deleted_at IS NULL AND coalesce(i.status, '') <> 'void'
    AND (l.description ~* 'memo|credit' OR EXISTS (SELECT 1 FROM supplier_invoices s WHERE s.supplier_id = public._wc_supplier()
      AND public._wc_key(s.supplier_invoice_number) IN (public._wc_key(m[1]))))
  ORDER BY i.id, m[1], l.id $f$;
REVOKE ALL ON FUNCTION public._wc_notes() FROM PUBLIC, anon, authenticated;

-- ties every note whose number is a Lennox credit on file (not one a person untied); returns how many it tied
CREATE OR REPLACE FUNCTION public._wc_autotie() RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v integer;
BEGIN
  WITH cr AS (SELECT id, public._wc_key(supplier_invoice_number) k FROM supplier_invoices
              WHERE supplier_id = public._wc_supplier() AND (doc_type IN ('credit', 'return') OR total < 0)),
  mt AS (SELECT DISTINCT cr.id cr_id, n.invoice_id FROM public._wc_notes() n JOIN cr ON cr.k <> '' AND (cr.k = n.k OR cr.k = n.k2)),
  ins AS (INSERT INTO supplier_invoice_customer_links (supplier_invoice_id, invoice_id, linked_by, auto)
    SELECT cr_id, invoice_id, public.current_app_user_id(), false FROM mt
    WHERE NOT EXISTS (SELECT 1 FROM supplier_invoice_customer_links k WHERE k.supplier_invoice_id = mt.cr_id AND k.invoice_id = mt.invoice_id)
      AND NOT EXISTS (SELECT 1 FROM supplier_invoice_customer_unlinks u WHERE u.supplier_invoice_id = mt.cr_id AND u.invoice_id = mt.invoice_id)
    RETURNING supplier_invoice_id, invoice_id),
  lg AS (INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
    SELECT 'supplier_invoice_customer_links', supplier_invoice_id, 'insert', public.current_app_user_id(),
      jsonb_build_object('invoice_id', invoice_id, 'why', 'Warranty credits page: the credit memo number is in the invoice note') FROM ins RETURNING 1)
  SELECT count(*) INTO v FROM lg;
  RETURN v;
END $f$;
REVOKE ALL ON FUNCTION public._wc_autotie() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.warranty_credits() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_cost boolean := public._can_see_costs(); v_tied integer; v_first date; v jsonb; v_loose jsonb;
BEGIN
  IF NOT coalesce(public._tank_office(), false) THEN RETURN jsonb_build_object('ok', false, 'rows', '[]'::jsonb); END IF;
  v_tied := public._wc_autotie();
  SELECT min(invoice_date) INTO v_first FROM supplier_invoices WHERE supplier_id = public._wc_supplier() AND (doc_type IN ('credit', 'return') OR total < 0);
  CREATE TEMP TABLE IF NOT EXISTS _wc_cr (id bigint, n text, k text, d date, t numeric, linked boolean) ON COMMIT DROP;
  TRUNCATE _wc_cr;
  INSERT INTO _wc_cr SELECT s.id, s.supplier_invoice_number, public._wc_key(s.supplier_invoice_number), s.invoice_date, s.total,
    EXISTS (SELECT 1 FROM supplier_invoice_customer_links l WHERE l.supplier_invoice_id = s.id)
  FROM supplier_invoices s WHERE s.supplier_id = public._wc_supplier() AND (s.doc_type IN ('credit', 'return') OR s.total < 0);
  WITH n AS (SELECT * FROM public._wc_notes()),
  r AS (
    SELECT n.*, i.invoice_number, i.invoice_date, i.job_id, j.job_number,
      (SELECT c FROM _wc_cr c WHERE c.k <> '' AND (c.k = n.k OR c.k = n.k2) ORDER BY c.id LIMIT 1) AS cr,
      (SELECT jsonb_agg(jsonb_build_object('id', c.id, 'number', c.n, 'date', c.d, 'total', CASE WHEN v_cost THEN c.t END))
         FROM _wc_cr c WHERE NOT c.linked AND length(c.k) = length(n.k) AND c.k <> n.k
           AND (SELECT count(*) FROM generate_series(1, length(c.k)) g WHERE substr(c.k, g, 1) <> substr(n.k, g, 1)) = 1) AS near,
      (SELECT jsonb_build_object('on', a.asked_on, 'by', e.first_name) FROM warranty_credit_asks a LEFT JOIN app_users u ON u.id = a.asked_by LEFT JOIN employees e ON e.id = u.employee_id
         WHERE a.memo = n.num AND a.invoice_id = n.invoice_id) AS asked
    FROM n JOIN invoices i ON i.id = n.invoice_id LEFT JOIN jobs j ON j.id = i.job_id)
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'inv', r.invoice_id, 'inv_no', r.invoice_number, 'date', r.invoice_date, 'job_id', r.job_id, 'job_no', r.job_number,
      'num', r.num, 'note', r.note, 'asked', r.asked, 'near', r.near,
      'credit', CASE WHEN (r.cr).id IS NOT NULL THEN jsonb_build_object('id', (r.cr).id, 'number', (r.cr).n, 'date', (r.cr).d,
        'total', CASE WHEN v_cost THEN (r.cr).t END) END,
      'st', CASE
        WHEN (r.cr).id IS NOT NULL AND EXISTS (SELECT 1 FROM supplier_invoice_customer_links l WHERE l.supplier_invoice_id = (r.cr).id AND l.invoice_id = r.invoice_id) THEN 'tied'
        WHEN (r.cr).id IS NOT NULL THEN 'untied'
        WHEN r.near IS NOT NULL THEN 'near'
        WHEN r.invoice_date < v_first THEN 'old'
        WHEN NOT (coalesce(r.k2, r.k) ~ '^6\d{8}$' OR coalesce(r.k2, r.k) ~ '^265\d{6}$') THEN 'typo'
        ELSE 'miss' END)
    ORDER BY r.invoice_date DESC, r.invoice_id DESC), '[]'::jsonb) INTO v FROM r;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'number', c.n, 'date', c.d, 'total', CASE WHEN v_cost THEN c.t END) ORDER BY c.d DESC), '[]'::jsonb)
    INTO v_loose FROM _wc_cr c WHERE NOT c.linked;
  RETURN jsonb_build_object('ok', true, 'rows', v, 'loose', v_loose, 'tied_now', v_tied, 'first', v_first, 'costs', v_cost,
    'customer', public._wc_customer(), 'supplier', public._wc_supplier());
END $f$;
GRANT EXECUTE ON FUNCTION public.warranty_credits() TO authenticated;

-- tie one Lennox credit to one warranty invoice (the close match, or one found by hand)
CREATE OR REPLACE FUNCTION public.warranty_credit_tie(p_credit bigint, p_invoice bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT coalesce(public._tank_office(), false) THEN RAISE EXCEPTION 'Only the office can tie a credit'; END IF;
  IF NOT EXISTS (SELECT 1 FROM supplier_invoices WHERE id = p_credit AND supplier_id = public._wc_supplier()) THEN RAISE EXCEPTION 'That is not a Lennox credit'; END IF;
  IF NOT EXISTS (SELECT 1 FROM invoices WHERE id = p_invoice AND customer_id = public._wc_customer()) THEN RAISE EXCEPTION 'That invoice is not on the warranty credit customer'; END IF;
  DELETE FROM supplier_invoice_customer_unlinks WHERE supplier_invoice_id = p_credit AND invoice_id = p_invoice;
  INSERT INTO supplier_invoice_customer_links (supplier_invoice_id, invoice_id, linked_by, auto)
    VALUES (p_credit, p_invoice, public.current_app_user_id(), false) ON CONFLICT DO NOTHING;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
    VALUES ('supplier_invoice_customer_links', p_credit, 'insert', public.current_app_user_id(), jsonb_build_object('invoice_id', p_invoice, 'why', 'Warranty credits page: tied by hand'));
  RETURN jsonb_build_object('ok', true);
END $f$;
GRANT EXECUTE ON FUNCTION public.warranty_credit_tie(bigint, bigint) TO authenticated;

-- "Asked Lennox" on a missing credit (p_on false takes it off)
CREATE OR REPLACE FUNCTION public.warranty_credit_ask(p_memo text, p_invoice bigint, p_on boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT coalesce(public._tank_office(), false) THEN RAISE EXCEPTION 'Only the office can mark this'; END IF;
  IF p_on THEN
    INSERT INTO warranty_credit_asks (memo, invoice_id, asked_by) VALUES (left(p_memo, 20), p_invoice, public.current_app_user_id())
      ON CONFLICT (memo, invoice_id) DO UPDATE SET asked_on = current_date, asked_by = excluded.asked_by;
  ELSE DELETE FROM warranty_credit_asks WHERE memo = p_memo AND invoice_id = p_invoice; END IF;
  RETURN jsonb_build_object('ok', true);
END $f$;
GRANT EXECUTE ON FUNCTION public.warranty_credit_ask(text, bigint, boolean) TO authenticated;

-- find a Lennox credit by its number (any part of it) or its amount, to tie by hand
CREATE OR REPLACE FUNCTION public.warranty_credit_find(p_q text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_cost boolean := public._can_see_costs(); v_d text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
  v_a numeric := CASE WHEN p_q ~ '^\s*-?\$?\s*[0-9,]*\.\d{1,2}\s*$' THEN abs(replace(replace(replace(p_q, '$', ''), ',', ''), ' ', '')::numeric) END;
BEGIN
  IF NOT coalesce(public._tank_office(), false) THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(x) FROM (
    SELECT jsonb_build_object('id', s.id, 'number', s.supplier_invoice_number, 'date', s.invoice_date, 'total', CASE WHEN v_cost THEN s.total END,
      'tied', (SELECT string_agg(i.invoice_number, ', ') FROM supplier_invoice_customer_links l JOIN invoices i ON i.id = l.invoice_id WHERE l.supplier_invoice_id = s.id)) x
    FROM supplier_invoices s WHERE s.supplier_id = public._wc_supplier() AND (s.doc_type IN ('credit', 'return') OR s.total < 0)
      AND ((v_a IS NOT NULL AND v_cost AND abs(abs(s.total) - v_a) < 0.01) OR (v_a IS NULL AND length(v_d) >= 4 AND regexp_replace(s.supplier_invoice_number, '\D', '', 'g') LIKE '%' || v_d || '%'))
    ORDER BY s.invoice_date DESC LIMIT 25) z), '[]'::jsonb);
END $f$;
GRANT EXECUTE ON FUNCTION public.warranty_credit_find(text) TO authenticated;

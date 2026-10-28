-- Supplier credits on store sales: Lennox sends credit memos ("COSTCO PAYMENTS" / "COSTCO CARRYOVER") to make up part of
-- what Costco keeps. Each line names the customer; it's connected to that customer's store sale (automatically by name, or by hand)
-- and shows on both invoice copies, the Sales page, the store's Payment history and the job costing (it lowers what the job cost).
CREATE TABLE IF NOT EXISTS public.partner_supplier_credits (
  id bigserial PRIMARY KEY,
  partner_id bigint NOT NULL,
  supplier_id bigint,
  supplier_name text NOT NULL,
  memo_no text NOT NULL,
  memo_date date,
  po text,
  kind text,
  amount numeric(12,2) NOT NULL,
  code text,
  ref text NOT NULL DEFAULT '',
  last_name text,
  first_name text,
  invoice_id bigint,            -- the customer's invoice of the store sale
  how text,                     -- auto | guess | hand
  matched_by bigint,
  imported_at timestamptz NOT NULL DEFAULT now(),
  imported_by bigint
);
CREATE UNIQUE INDEX IF NOT EXISTS partner_supplier_credits_uq ON public.partner_supplier_credits (supplier_name, memo_no, ref, amount);
CREATE INDEX IF NOT EXISTS partner_supplier_credits_inv ON public.partner_supplier_credits (invoice_id);
ALTER TABLE public.partner_supplier_credits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.partner_supplier_credits FROM PUBLIC, anon, authenticated;

-- connect by the customer's name on the store's sales (closest invoice before the memo); hand matches stay
CREATE INDEX IF NOT EXISTS invoices_paid_at_store ON public.invoices (id) WHERE paid_at_store;
CREATE OR REPLACE FUNCTION public._partner_credits_match(p_partner bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_done int; v_pname text; v_pcust bigint;
BEGIN
  SELECT name, customer_account_id INTO v_pname, v_pcust FROM partners WHERE id = p_partner;
  UPDATE partner_supplier_credits SET invoice_id = NULL, how = NULL WHERE partner_id = p_partner AND how IN ('auto', 'guess');
  WITH pc AS (SELECT id FROM customers WHERE id = v_pcust OR display_name ILIKE v_pname || '%'),
  ids AS (   -- the store's sales, each found by an index
    SELECT i.id FROM jobs j JOIN invoices i ON i.job_id = j.id WHERE j.partner_id = p_partner
    UNION SELECT i.id FROM invoices i WHERE i.bill_to_partner_id = p_partner
    UNION SELECT i.id FROM invoices i WHERE i.paid_at_store
    UNION SELECT i.id FROM invoices i WHERE i.customer_id IN (SELECT id FROM pc)
    UNION SELECT i.id FROM jobs j JOIN invoices i ON i.job_id = j.id WHERE j.customer_id IN (SELECT id FROM pc)
    UNION SELECT m.invoice_id FROM partner_statement_matches m WHERE m.partner_id = p_partner AND m.invoice_id IS NOT NULL),
  sales AS MATERIALIZED (
    SELECT i.id, i.job_id, i.invoice_date, upper(concat_ws(' | ', c1.display_name, c2.display_name, lo.name)) AS names
    FROM ids JOIN invoices i ON i.id = ids.id
    LEFT JOIN jobs j ON j.id = i.job_id
    LEFT JOIN locations lo ON lo.id = coalesce(i.location_id, j.location_id)
    LEFT JOIN customers c1 ON c1.id = lo.customer_id
    LEFT JOIN customers c2 ON c2.id = coalesce(j.customer_id, i.customer_id)
    WHERE i.store_copy_of IS NULL AND i.status NOT IN ('void', 'draft') AND i.subtotal > 0),
  pick AS (
    SELECT c.id AS credit_id, b.id AS inv, b.n
    FROM partner_supplier_credits c
    CROSS JOIN LATERAL (
      SELECT s.id, count(DISTINCT coalesce(s.job_id, s.id)) OVER () AS n,
             row_number() OVER (ORDER BY (s.invoice_date <= coalesce(c.memo_date, current_date)) DESC, abs(coalesce(c.memo_date, current_date) - s.invoice_date), s.id DESC) AS rn
      FROM sales s
      WHERE position(upper(c.last_name) in s.names) > 0
        AND (coalesce(c.first_name, '') = '' OR position(upper(split_part(c.first_name, ' ', 1)) in s.names) > 0)) b
    WHERE c.partner_id = p_partner AND c.invoice_id IS NULL AND c.how IS NULL AND coalesce(c.last_name, '') <> '' AND b.rn = 1)
  UPDATE partner_supplier_credits c SET invoice_id = pick.inv, how = CASE WHEN pick.n = 1 THEN 'auto' ELSE 'guess' END
  FROM pick WHERE c.id = pick.credit_id;
  GET DIAGNOSTICS v_done = ROW_COUNT;
  RETURN v_done;
END $function$;

-- p_rows: [{memo_no, memo_date, po, kind, amount, code, ref, last_name, first_name}]
CREATE OR REPLACE FUNCTION public.partner_credits_import(p_partner bigint, p_supplier_name text, p_rows jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_new int; v_sup bigint;
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'You don''t have permission to change partner payments'; END IF;
  SELECT id INTO v_sup FROM suppliers WHERE name ILIKE btrim(p_supplier_name) || '%' ORDER BY id LIMIT 1;
  WITH ins AS (
    INSERT INTO partner_supplier_credits (partner_id, supplier_id, supplier_name, memo_no, memo_date, po, kind, amount, code, ref, last_name, first_name, imported_by)
    SELECT p_partner, v_sup, btrim(p_supplier_name), btrim(x->>'memo_no'), nullif(x->>'memo_date', '')::date, nullif(btrim(x->>'po'), ''), nullif(btrim(x->>'kind'), ''),
           (x->>'amount')::numeric, nullif(btrim(x->>'code'), ''), coalesce(btrim(x->>'ref'), ''), nullif(btrim(x->>'last_name'), ''), nullif(btrim(x->>'first_name'), ''),
           public.current_app_user_id()
    FROM jsonb_array_elements(p_rows) x WHERE coalesce(btrim(x->>'memo_no'), '') <> '' AND x->>'amount' IS NOT NULL
    ON CONFLICT (supplier_name, memo_no, ref, amount) DO NOTHING RETURNING 1)
  SELECT count(*) INTO v_new FROM ins;
  RETURN jsonb_build_object('rows', jsonb_array_length(p_rows), 'new', v_new, 'matched', public._partner_credits_match(p_partner));
END $function$;

CREATE OR REPLACE FUNCTION public.partner_credits_list(p_partner bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'You don''t have permission to see partner payments'; END IF;
  RETURN coalesce((SELECT jsonb_agg(row_to_json(t) ORDER BY t.memo_date DESC, t.memo_no DESC, t.id) FROM (
    SELECT c.id, c.supplier_name, c.memo_no, c.memo_date, c.po, c.kind, c.amount, c.code, c.ref, c.last_name, c.first_name, c.how,
           i.id invoice_id, i.invoice_number, i.invoice_date, i.job_id,
           coalesce(lo.customer_id, j.customer_id, i.customer_id) customer_id, coalesce(lc.display_name, lo.name, cu.display_name) customer_name, lo.street, lo.city
    FROM partner_supplier_credits c
    LEFT JOIN invoices i ON i.id = c.invoice_id LEFT JOIN jobs j ON j.id = i.job_id
    LEFT JOIN locations lo ON lo.id = coalesce(i.location_id, j.location_id) LEFT JOIN customers lc ON lc.id = lo.customer_id
    LEFT JOIN customers cu ON cu.id = i.customer_id
    WHERE c.partner_id = p_partner) t), '[]'::jsonb);
END $function$;

-- by hand: our invoice # or job # ('' = take it off)
CREATE OR REPLACE FUNCTION public.partner_credit_set(p_id bigint, p_number text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_inv bigint; v_num text := regexp_replace(coalesce(p_number, ''), '[^0-9A-Za-z]', '', 'g');
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'You don''t have permission to change partner payments'; END IF;
  IF v_num = '' THEN UPDATE partner_supplier_credits SET invoice_id = NULL, how = 'none', matched_by = public.current_app_user_id() WHERE id = p_id; RETURN; END IF;
  SELECT id INTO v_inv FROM invoices WHERE invoice_number = v_num AND subtotal > 0 AND store_copy_of IS NULL ORDER BY invoice_date DESC LIMIT 1;
  IF v_inv IS NULL THEN SELECT i.id INTO v_inv FROM invoices i JOIN jobs j ON j.id = i.job_id WHERE j.job_number = v_num AND i.store_copy_of IS NULL ORDER BY i.subtotal DESC, i.invoice_date DESC LIMIT 1; END IF;
  IF v_inv IS NULL THEN RAISE EXCEPTION 'No invoice or job % found', p_number; END IF;
  UPDATE partner_supplier_credits SET invoice_id = v_inv, how = 'hand', matched_by = public.current_app_user_id() WHERE id = p_id;
END $function$;

CREATE OR REPLACE FUNCTION public.partner_credits_match(p_partner bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'You don''t have permission to change partner payments'; END IF;
  RETURN public._partner_credits_match(p_partner);
END $function$;
REVOKE EXECUTE ON FUNCTION public._partner_credits_match(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.partner_credits_import(bigint, text, jsonb), public.partner_credits_list(bigint), public.partner_credit_set(bigint, text), public.partner_credits_match(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.partner_credits_import(bigint, text, jsonb), public.partner_credits_list(bigint), public.partner_credit_set(bigint, text), public.partner_credits_match(bigint) TO authenticated;

-- invoices (both copies): the store's payments and the supplier's credits
CREATE OR REPLACE FUNCTION public.store_payments(p_invoice bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_src bigint;
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN '[]'::jsonb; END IF;
  SELECT coalesce(store_copy_of, id) INTO v_src FROM invoices WHERE id = p_invoice;
  RETURN coalesce((SELECT jsonb_agg(z ORDER BY z->>'date', z->>'payment_no') FROM (
    SELECT jsonb_build_object('kind', 'store', 'store', p.name, 'date', x.d, 'amount', x.net, 'payment_no', x.payment_no, 'doc_no', x.doc_no, 'po', x.po) z
    FROM (SELECT l.partner_id, l.payment_no, max(l.payment_date) d, sum(l.net) net, string_agg(DISTINCT l.doc_no, ', ') doc_no, max(l.po_no) po
          FROM partner_statement_matches m JOIN partner_statement_lines l ON l.partner_id = m.partner_id AND l.doc_no = m.doc_no
          WHERE m.invoice_id = v_src GROUP BY l.partner_id, l.payment_no) x JOIN partners p ON p.id = x.partner_id
    UNION ALL
    SELECT jsonb_build_object('kind', 'credit', 'store', c.supplier_name, 'date', c.memo_date, 'amount', c.amount, 'payment_no', c.memo_no, 'doc_no', c.ref, 'po', c.po, 'what', c.kind)
    FROM partner_supplier_credits c WHERE c.invoice_id = v_src) q), '[]'::jsonb);
END $function$;

-- Sales page: Costco's payment and the supplier credits on each job
CREATE OR REPLACE FUNCTION public.store_paid_jobs() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('job_id', coalesce(x.job_id, cr.job_id), 'store', x.store, 'date', x.d, 'payment_no', x.pn, 'doc_no', x.docs, 'amount', x.net,
                                                       'credit', cr.amt, 'credit_from', cr.sup, 'credit_memo', cr.memos))
    FROM (SELECT i.job_id, max(p.name) store, max(l.payment_date) d, string_agg(DISTINCT l.payment_no, ', ') pn, string_agg(DISTINCT l.doc_no, ', ') docs, sum(l.net) net
          FROM partner_statement_matches m JOIN partner_statement_lines l ON l.partner_id = m.partner_id AND l.doc_no = m.doc_no
          JOIN invoices i ON i.id = m.invoice_id JOIN partners p ON p.id = l.partner_id WHERE i.job_id IS NOT NULL GROUP BY i.job_id) x
    FULL JOIN (SELECT i.job_id, sum(c.amount) amt, string_agg(DISTINCT c.supplier_name, ', ') sup, string_agg(DISTINCT c.memo_no, ', ') memos
               FROM partner_supplier_credits c JOIN invoices i ON i.id = c.invoice_id WHERE i.job_id IS NOT NULL GROUP BY i.job_id) cr ON cr.job_id = x.job_id), '[]'::jsonb);
END $function$;

-- job costing: the supplier's credit lowers what the job cost
SELECT public._patch_fn('inv_costing', $o$'hst', public._hst(),$o$,
  $n$'hst', public._hst(), 'supplier_credit', (SELECT coalesce(sum(c.amount), 0) FROM partner_supplier_credits c WHERE c.invoice_id = (SELECT coalesce(i.store_copy_of, i.id) FROM i)),
    'supplier_credit_from', (SELECT string_agg(DISTINCT c.supplier_name, ', ') FROM partner_supplier_credits c WHERE c.invoice_id = (SELECT coalesce(i.store_copy_of, i.id) FROM i)),$n$);
NOTIFY pgrst, 'reload schema';

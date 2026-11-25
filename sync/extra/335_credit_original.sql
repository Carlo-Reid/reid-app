-- A supplier's credit is tied to the supplier's ORIGINAL invoice (the one it credits back), not to one of our customer invoices
-- (Carlo, Nov 25, 2026: "when an invoice is a Credit Memo do not have it try to connect to an invoice have it connect to the original
-- purchase invoice from the supplier"). The original is found by itself (the "original order" number printed on the credit), or
-- picked by a person and kept in supplier_credit_original.
CREATE TABLE IF NOT EXISTS public.supplier_credit_original (
  credit_id  bigint PRIMARY KEY,
  invoice_id bigint,              -- null = a person said it has no original in our system
  by_email   text,
  at         timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.supplier_credit_original ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public._sinv_num_key(t text) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT nullif(upper(regexp_replace(coalesce(t, ''), '[^A-Za-z0-9]', '', 'g')), '') $$;

-- p_q: a search typed by the person (a number or an amount). Answers:
-- { link: {id, number, date, subtotal, total, po, how: 'hand'|'number'|'po'}, none: true when a person said there is none,
--   suggest: [...], rows: [...] (only with p_q) }
CREATE OR REPLACE FUNCTION public.sinv_credit_original(p_id bigint, p_q text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE c supplier_invoices; h supplier_credit_original; v_po bigint; v_num text; lk jsonb; how text; v_id bigint; q text; amt numeric;
BEGIN
  IF NOT (public._sinv_can_edit() OR public._can_see_costs()) THEN RETURN '{}'::jsonb; END IF;
  SELECT * INTO c FROM supplier_invoices WHERE id = p_id; IF c.id IS NULL THEN RETURN '{}'::jsonb; END IF;
  v_po := public._sinv_po(c); IF v_po IS NOT NULL THEN SELECT po_number INTO v_num FROM purchase_orders WHERE id = v_po; END IF;
  SELECT * INTO h FROM supplier_credit_original WHERE credit_id = p_id;
  IF h.credit_id IS NOT NULL THEN v_id := h.invoice_id; how := 'hand';
  ELSE
    SELECT i.id INTO v_id FROM supplier_invoices i
     WHERE i.supplier_id = c.supplier_id AND i.id <> c.id AND i.total > 0 AND coalesce(i.doc_type, 'invoice') NOT IN ('credit', 'return')
       AND public._sinv_num_key(i.supplier_invoice_number) = public._sinv_num_key(c.original_order)
     ORDER BY abs(i.total + c.total), i.invoice_date DESC LIMIT 1;
    IF v_id IS NOT NULL THEN how := 'number';
    ELSIF v_po IS NOT NULL THEN   -- one invoice on the same P.O. for the same amount
      SELECT CASE WHEN count(*) = 1 THEN min(i.id) END INTO v_id FROM supplier_invoices i
       WHERE i.supplier_id = c.supplier_id AND i.id <> c.id AND i.total > 0 AND coalesce(i.doc_type, 'invoice') NOT IN ('credit', 'return')
         AND (i.purchase_order_id = v_po OR btrim(i.po_text) = v_num OR btrim(i.po_text) = split_part(v_num, '-', 1)) AND abs(i.total + c.total) <= 1;
      IF v_id IS NOT NULL THEN how := 'po'; END IF;
    END IF;
  END IF;
  IF v_id IS NOT NULL THEN
    SELECT jsonb_build_object('id', i.id, 'number', i.supplier_invoice_number, 'date', i.invoice_date, 'subtotal', i.subtotal, 'total', i.total,
             'po', (SELECT po_number FROM purchase_orders WHERE id = i.purchase_order_id), 'how', how) INTO lk FROM supplier_invoices i WHERE i.id = v_id;
  END IF;
  q := nullif(btrim(coalesce(p_q, '')), '');
  IF q ~ '^\$?-?[0-9,]*\.[0-9]{1,2}$' THEN amt := abs(replace(replace(replace(q, '$', ''), ',', ''), '-', '')::numeric); END IF;
  RETURN jsonb_build_object('link', lk, 'none', (h.credit_id IS NOT NULL AND h.invoice_id IS NULL), 'printed', c.original_order,
    'suggest', (SELECT coalesce(jsonb_agg(x ORDER BY (x->>'k')::int, x->>'date' DESC), '[]'::jsonb) FROM (
       SELECT jsonb_build_object('id', i.id, 'number', i.supplier_invoice_number, 'date', i.invoice_date, 'subtotal', i.subtotal, 'total', i.total,
                'po', (SELECT po_number FROM purchase_orders WHERE id = i.purchase_order_id),
                'k', CASE WHEN v_po IS NOT NULL AND i.purchase_order_id = v_po THEN 0 WHEN abs(i.total + c.total) <= 1 THEN 1 ELSE 2 END,
                'why', concat_ws(' · ', CASE WHEN v_po IS NOT NULL AND (i.purchase_order_id = v_po OR btrim(i.po_text) = v_num) THEN 'same P.O.' END,
                                        CASE WHEN abs(i.total + c.total) <= 1 THEN 'same amount' END)) AS x
       FROM supplier_invoices i
       WHERE i.supplier_id = c.supplier_id AND i.id <> c.id AND i.total > 0 AND coalesce(i.doc_type, 'invoice') NOT IN ('credit', 'return')
         AND i.id IS DISTINCT FROM v_id
         AND ((v_po IS NOT NULL AND (i.purchase_order_id = v_po OR btrim(i.po_text) = v_num OR btrim(i.po_text) = split_part(v_num, '-', 1)))
              OR (abs(i.total + c.total) <= 1 AND i.invoice_date BETWEEN coalesce(c.invoice_date, current_date) - 365 AND coalesce(c.invoice_date, current_date) + 5))
       LIMIT 8) s),
    'rows', CASE WHEN q IS NULL THEN NULL ELSE (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM (
       SELECT jsonb_build_object('id', i.id, 'number', i.supplier_invoice_number, 'date', i.invoice_date, 'subtotal', i.subtotal, 'total', i.total,
                'po', (SELECT po_number FROM purchase_orders WHERE id = i.purchase_order_id)) AS x
       FROM supplier_invoices i
       WHERE i.supplier_id = c.supplier_id AND i.id <> c.id AND i.total > 0 AND coalesce(i.doc_type, 'invoice') NOT IN ('credit', 'return')
         AND (CASE WHEN amt IS NOT NULL THEN abs(i.total - amt) <= 0.01 OR abs(coalesce(i.subtotal, 0) - amt) <= 0.01
                   ELSE public._sinv_num_key(i.supplier_invoice_number) LIKE '%' || public._sinv_num_key(q) || '%'
                        OR i.po_text ILIKE '%' || q || '%' END)
       ORDER BY i.invoice_date DESC LIMIT 20) s) END);
END $$;
REVOKE EXECUTE ON FUNCTION public.sinv_credit_original(bigint, text) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.sinv_credit_original(bigint, text) TO authenticated;

-- p_mode: 'set' = tie to p_invoice, 'none' = there is no original in our system, 'auto' = forget the hand pick
CREATE OR REPLACE FUNCTION public.sinv_credit_original_set(p_id bigint, p_invoice bigint, p_mode text DEFAULT 'set')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE c supplier_invoices; i supplier_invoices;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You can not change supplier invoices'; END IF;
  SELECT * INTO c FROM supplier_invoices WHERE id = p_id; IF c.id IS NULL THEN RAISE EXCEPTION 'That credit is not there'; END IF;
  IF p_mode = 'auto' THEN DELETE FROM supplier_credit_original WHERE credit_id = p_id; RETURN; END IF;
  IF p_mode = 'set' THEN
    SELECT * INTO i FROM supplier_invoices WHERE id = p_invoice;
    IF i.id IS NULL OR i.supplier_id <> c.supplier_id THEN RAISE EXCEPTION 'That invoice is not from the same supplier'; END IF;
  END IF;
  INSERT INTO supplier_credit_original (credit_id, invoice_id, by_email, at)
  VALUES (p_id, CASE WHEN p_mode = 'set' THEN p_invoice END, auth.jwt()->>'email', now())
  ON CONFLICT (credit_id) DO UPDATE SET invoice_id = EXCLUDED.invoice_id, by_email = EXCLUDED.by_email, at = now();
  INSERT INTO audit_log (table_name, record_id, action, new_values)
  VALUES ('supplier_invoices', p_id, 'update', jsonb_build_object('original_invoice', CASE WHEN p_mode = 'set' THEN i.supplier_invoice_number ELSE 'none' END));
END $$;
REVOKE EXECUTE ON FUNCTION public.sinv_credit_original_set(bigint, bigint, text) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.sinv_credit_original_set(bigint, bigint, text) TO authenticated;

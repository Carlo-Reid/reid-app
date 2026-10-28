-- How a store pays us. Two ways:
--   'cut'           (old) the store keeps a % of the total with tax, less a gift card fee
--   'discount_fee'  (Costco) the store takes X% off our price before tax, adds HST on what's left,
--                   then keeps Y% of our original price (+ a flat $ per invoice) as its fee.
--   e.g. 5490: 11% off = 4886.10, + HST 635.19 = 5521.29, less 10% of 5490 (549.00) + 1.50 = 4970.79 paid to us.
-- When the store's payment history (partner_statement_lines) is connected to the invoice, what they really paid wins.
-- Costco: switched once to the Costco way when the setting first appears (all its invoices follow, unless one is set to the old way by hand)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'partners' AND column_name = 'pay_method') THEN
    ALTER TABLE public.partners ADD COLUMN pay_method text NOT NULL DEFAULT 'cut';
    ALTER TABLE public.partners ADD COLUMN IF NOT EXISTS discount_pct numeric NOT NULL DEFAULT 11;
    ALTER TABLE public.partners ADD COLUMN IF NOT EXISTS fee_pct numeric NOT NULL DEFAULT 10;
    ALTER TABLE public.partners ADD COLUMN IF NOT EXISTS fee_flat numeric NOT NULL DEFAULT 0;
    UPDATE public.partners SET pay_method = 'discount_fee', discount_pct = 11, fee_pct = 10, fee_flat = 1.50 WHERE name = 'Costco';
  END IF;
END $$;
ALTER TABLE public.partners ADD COLUMN IF NOT EXISTS discount_pct numeric NOT NULL DEFAULT 11;
ALTER TABLE public.partners ADD COLUMN IF NOT EXISTS fee_pct numeric NOT NULL DEFAULT 10;
ALTER TABLE public.partners ADD COLUMN IF NOT EXISTS fee_flat numeric NOT NULL DEFAULT 0;
ALTER TABLE public.partner_invoice_terms ADD COLUMN IF NOT EXISTS method text;          -- null = the store's way
ALTER TABLE public.partner_invoice_terms ADD COLUMN IF NOT EXISTS discount_pct numeric; -- null = the store's %
ALTER TABLE public.partner_invoice_terms ADD COLUMN IF NOT EXISTS fee_amount numeric;   -- null = worked out

CREATE OR REPLACE FUNCTION public._partner_pay(p_invoice bigint, p_partner bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i record; p record; t record; v_method text; v_card numeric; v_sub numeric; v_total numeric;
        v_d numeric; v_disc numeric := 0; v_after numeric; v_rate numeric; v_tax numeric; v_fee numeric := 0; v_cut numeric; v_pays numeric; v_calc numeric; v_st numeric; v_stn int;
BEGIN
  SELECT subtotal, tax_total, total INTO i FROM invoices WHERE id = p_invoice;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO p FROM partners WHERE id = p_partner;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT method, card_fee, cut_pct, discount_pct, fee_amount INTO t FROM partner_invoice_terms WHERE invoice_id = p_invoice;
  IF NOT FOUND THEN SELECT NULL::text method, NULL::numeric card_fee, NULL::numeric cut_pct, NULL::numeric discount_pct, NULL::numeric fee_amount INTO t; END IF;
  v_method := coalesce(t.method, p.pay_method, 'cut');
  v_card := coalesce(t.card_fee, p.default_card_fee, 0);
  v_sub := coalesce(i.subtotal, 0); v_total := coalesce(i.total, 0);
  IF v_method = 'discount_fee' THEN
    v_d := coalesce(t.discount_pct, p.discount_pct, 11);
    v_disc := round(v_sub * v_d / 100, 2);
    v_after := v_sub - v_disc;
    v_rate := CASE WHEN v_sub > 0 AND coalesce(i.tax_total, 0) > 0 THEN i.tax_total / v_sub ELSE 0 END;
    v_tax := round(v_after * v_rate, 2);
    v_fee := coalesce(t.fee_amount, round(v_sub * coalesce(p.fee_pct, 10) / 100, 2) + coalesce(p.fee_flat, 0));
    v_calc := v_after + v_tax - v_fee - v_card;
  ELSE
    v_cut := coalesce(t.cut_pct, p.default_cut_pct, 0);
    v_calc := v_total - round(v_total * v_cut / 100, 2) - v_card;
  END IF;
  SELECT sum(l.net), count(*) INTO v_st, v_stn FROM partner_statement_lines l
    JOIN partner_statement_matches m ON m.partner_id = l.partner_id AND m.doc_no = l.doc_no
    WHERE m.invoice_id = p_invoice AND l.partner_id = p_partner;
  v_pays := CASE WHEN v_stn > 0 THEN v_st ELSE v_calc END;
  RETURN jsonb_build_object('method', v_method, 'sale', v_sub, 'total', v_total, 'card', v_card,
    'cut_pct', CASE WHEN v_method = 'cut' THEN v_cut END,
    'discount_pct', CASE WHEN v_method = 'discount_fee' THEN v_d END, 'discount', v_disc, 'after', v_after, 'tax', v_tax, 'fee', v_fee,
    'calc', v_calc, 'pays', v_pays, 'keeps', v_total - v_pays - v_card,
    'from_statement', v_stn > 0, 'statement_diff', CASE WHEN v_stn > 0 THEN round(v_st - v_calc, 2) END,
    'own', t.method IS NOT NULL OR t.discount_pct IS NOT NULL OR t.fee_amount IS NOT NULL);
END $function$;

DROP FUNCTION IF EXISTS public.partner_ledger(bigint, text, date, date);
CREATE FUNCTION public.partner_ledger(p_partner bigint, p_show text, p_from date, p_to date)
 RETURNS TABLE(invoice_id bigint, invoice_number text, invoice_date date, customer_id bigint, customer_name text, street text, city text, job_type text, total numeric, cut_pct numeric, cut_amount numeric, card_fee numeric, expected numeric, received numeric, still_due numeric, reference text, sent_on date, notes text, settled boolean, own_terms boolean, status text, account text, approval text, signed boolean, missing text[], supplier_amount numeric, supplier_name text, supplier_status text, pay jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  WITH p AS (SELECT * FROM partners WHERE id = p_partner),
  inv AS (
    SELECT i.*, j.job_type_id FROM invoices i JOIN jobs j ON j.id = i.job_id
    WHERE j.partner_id = p_partner AND NOT (SELECT bill_to_ok AND NOT customer_pays_partner FROM p)
      AND i.status NOT IN ('void', 'draft') AND i.total > 0
      AND coalesce(i.look, '') <> 'reid' AND NOT (coalesce(i.look, '') = 'store' AND i.branding_partner_id IS DISTINCT FROM p_partner)
      AND NOT EXISTS (SELECT 1 FROM partners b WHERE b.id = i.bill_to_partner_id AND b.id <> p_partner AND b.bill_to_ok)
    UNION
    SELECT i.*, j.job_type_id FROM invoices i LEFT JOIN jobs j ON j.id = i.job_id
    WHERE i.bill_to_partner_id = p_partner AND i.status NOT IN ('void', 'draft') AND i.total > 0
      AND (coalesce(i.look, '') <> 'reid' OR (SELECT bill_to_ok FROM p))),
  calc AS (
    SELECT i.id, i.invoice_number, i.invoice_date, c.id AS cid, c.display_name, l.street, l.city, t.name AS jt, i.total,
           CASE WHEN p.bill_to_ok AND NOT p.customer_pays_partner THEN jsonb_build_object('method', 'cut', 'cut_pct', 0, 'card', 0, 'pays', i.total, 'keeps', 0)
                ELSE public._partner_pay(i.id, p.id) END AS pay,
           coalesce((SELECT sum(rl.amount) FROM partner_remittance_lines rl WHERE rl.invoice_id = i.id), 0)
             + CASE WHEN p.bill_to_ok AND NOT p.customer_pays_partner THEN coalesce(i.amount_paid, 0)
                    ELSE coalesce((SELECT sum(pa.amount) FROM payment_applications pa JOIN payments pm ON pm.id = pa.payment_id
                                   WHERE pa.invoice_id = i.id AND pm.method = 'partner_remittance'), 0) END AS got,
           pt.reference, pt.sent_on, pt.notes, pt.settled_at IS NOT NULL OR (p.bill_to_ok AND i.not_owed_reason IS NOT NULL) AS settled, pt.invoice_id IS NOT NULL AS own,
           i.partner_account, i.authorization_number, (i.signature_png IS NOT NULL OR i.signed_at IS NOT NULL) AS signed,
           CASE WHEN p.bill_to_ok AND i.bill_to_partner_id = p.id THEN public._inv_partner_missing(i.id) ELSE '{}'::text[] END AS missing,
           coalesce(sp.amount, 0) AS sup, sp.sname, sp.status AS sstatus
    FROM inv i CROSS JOIN p
    JOIN customers c ON c.id = i.customer_id
    LEFT JOIN locations l ON l.id = i.location_id
    LEFT JOIN job_types t ON t.id = i.job_type_id
    LEFT JOIN partner_invoice_terms pt ON pt.invoice_id = i.id
    LEFT JOIN LATERAL (SELECT x.amount, s.name AS sname, x.status FROM third_party_supplier_payments x JOIN suppliers s ON s.id = x.supplier_id
                       WHERE x.invoice_id = i.id AND x.partner_id = p.id) sp ON true),
  m AS (SELECT *, coalesce((pay->>'pays')::numeric, total) - sup AS exp, coalesce((pay->>'keeps')::numeric, 0) AS keeps, coalesce((pay->>'card')::numeric, 0) AS card FROM calc)
  SELECT id, invoice_number, invoice_date, cid, display_name, street, city, jt, total,
         CASE WHEN pay->>'method' = 'cut' THEN (pay->>'cut_pct')::numeric ELSE CASE WHEN total > 0 THEN round(keeps / total * 100, 1) ELSE 0 END END,
         keeps, card,
         exp, got, greatest(exp - got, 0),
         reference, sent_on, notes, settled, own,
         CASE WHEN settled OR exp - got <= 0.01 THEN 'paid' WHEN got > 0 THEN 'part' ELSE 'waiting' END,
         partner_account, authorization_number, signed, missing, sup, sname, sstatus, pay
  FROM m
  WHERE public._can_partner_pay()
    AND (p_from IS NULL OR invoice_date >= p_from) AND (p_to IS NULL OR invoice_date <= p_to)
    AND CASE coalesce(p_show, 'waiting')
          WHEN 'waiting' THEN NOT settled AND exp - got > 0.01
          WHEN 'paid' THEN settled OR exp - got <= 0.01
          ELSE true END
  ORDER BY invoice_date DESC, id DESC
$function$;
REVOKE EXECUTE ON FUNCTION public.partner_ledger(bigint, text, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.partner_ledger(bigint, text, date, date) TO authenticated;

-- the store's way (owners / accounting)
CREATE OR REPLACE FUNCTION public.partner_pay_method_set(p_partner bigint, p_method text, p_discount numeric, p_fee_pct numeric, p_fee_flat numeric) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'You don''t have permission to change partner payments'; END IF;
  IF p_method NOT IN ('cut', 'discount_fee') THEN RAISE EXCEPTION 'Pick how they pay'; END IF;
  IF p_discount NOT BETWEEN 0 AND 60 OR p_fee_pct NOT BETWEEN 0 AND 60 OR p_fee_flat < 0 THEN RAISE EXCEPTION 'Check the % off, the fee % and the $ fee'; END IF;
  UPDATE partners SET pay_method = p_method, discount_pct = p_discount, fee_pct = p_fee_pct, fee_flat = p_fee_flat WHERE id = p_partner;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('partners', p_partner, 'update', public.current_app_user_id(), jsonb_build_object('pay_method', p_method, 'discount_pct', p_discount, 'fee_pct', p_fee_pct, 'fee_flat', p_fee_flat));
END $function$;

-- one invoice or many: which way ('' = the store's way), its own % off, its own fee ('' = worked out)
CREATE OR REPLACE FUNCTION public.partner_invoice_method_set(p_invoice_ids bigint[], p jsonb) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_n int;
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'You don''t have permission to change partner payments'; END IF;
  IF p ? 'method' AND nullif(p->>'method', '') IS NOT NULL AND p->>'method' NOT IN ('cut', 'discount_fee') THEN RAISE EXCEPTION 'Pick how they pay'; END IF;
  IF nullif(p->>'discount_pct', '') IS NOT NULL AND (p->>'discount_pct')::numeric NOT BETWEEN 0 AND 60 THEN RAISE EXCEPTION 'The % off must be between 0 and 60'; END IF;
  IF nullif(p->>'fee_amount', '') IS NOT NULL AND (p->>'fee_amount')::numeric < 0 THEN RAISE EXCEPTION 'The fee can''t be below zero'; END IF;
  INSERT INTO partner_invoice_terms (invoice_id) SELECT unnest(p_invoice_ids) ON CONFLICT DO NOTHING;
  UPDATE partner_invoice_terms SET
    method = CASE WHEN p ? 'method' THEN nullif(p->>'method', '') ELSE method END,
    cut_pct = CASE WHEN p ? 'method' AND p->>'method' IS DISTINCT FROM 'cut' THEN NULL ELSE cut_pct END,   -- leaving the old way: forget its % cut
    discount_pct = CASE WHEN p ? 'discount_pct' THEN nullif(p->>'discount_pct', '')::numeric ELSE discount_pct END,
    fee_amount = CASE WHEN p ? 'fee_amount' THEN nullif(p->>'fee_amount', '')::numeric ELSE fee_amount END,
    updated_by = public.current_app_user_id(), updated_at = now()
  WHERE invoice_id = ANY (p_invoice_ids);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  SELECT 'partner_invoice_terms', x, 'update', public.current_app_user_id(), p FROM unnest(p_invoice_ids) x;
  RETURN v_n;
END $function$;

-- partner_stores: also say how the store pays
DROP FUNCTION IF EXISTS public.partner_stores();
CREATE FUNCTION public.partner_stores()
 RETURNS TABLE(id bigint, name text, default_cut_pct numeric, default_card_fee numeric, invoices bigint, still_owed numeric, pays_us boolean, needs_signature boolean, needs_account boolean, needs_approval boolean, terms_days integer, kind text,
               pay_method text, discount_pct numeric, fee_pct numeric, fee_flat numeric, old_way bigint)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT p.id, p.name, p.default_cut_pct, p.default_card_fee,
         (SELECT count(*) FROM partner_ledger(p.id, 'waiting', NULL, NULL)),
         (SELECT coalesce(sum(still_due), 0) FROM partner_ledger(p.id, 'waiting', NULL, NULL)),
         p.bill_to_ok AND NOT p.customer_pays_partner,
         p.needs_signature, p.requires_partner_reference, p.requires_authorization, p.payment_terms_days,
         (SELECT t.name FROM partner_types t WHERE t.id = p.partner_type_id),
         p.pay_method, p.discount_pct, p.fee_pct, p.fee_flat,
         CASE WHEN p.pay_method = 'discount_fee' THEN (SELECT count(*) FROM partner_ledger(p.id, 'all', NULL, NULL) x WHERE x.pay->>'method' = 'cut') ELSE 0 END
  FROM partners p
  WHERE public._can_partner_pay() AND (p.customer_pays_partner OR p.bill_to_ok) AND p.active
  ORDER BY (p.name = 'Costco') DESC, p.bill_to_ok, p.name
$function$;
REVOKE EXECUTE ON FUNCTION public.partner_stores(), public._partner_pay(bigint, bigint), public.partner_pay_method_set(bigint, text, numeric, numeric, numeric), public.partner_invoice_method_set(bigint[], jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.partner_stores(), public.partner_pay_method_set(bigint, text, numeric, numeric, numeric), public.partner_invoice_method_set(bigint[], jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public._partner_pay(bigint, bigint) TO authenticated;

-- job costing: what the store keeps, worked out the same way
DO $$ DECLARE s text; BEGIN
  s := pg_get_functiondef('public.inv_costing(bigint)'::regprocedure);
  IF position('_partner_pay' in s) = 0 THEN
    s := replace(s, $r$'own_terms', EXISTS (SELECT 1 FROM terms))$r$, $r$'own_terms', EXISTS (SELECT 1 FROM terms), 'pay', public._partner_pay((SELECT i.id FROM i), st.id))$r$);
    EXECUTE s;
  END IF;
END $$;
NOTIFY pgrst, 'reload schema';

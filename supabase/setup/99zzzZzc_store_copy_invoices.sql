-- Two invoices for a store sale (Costco):
--   the customer's copy: what we charged the customer, paid in full at the store (never owed to us, not counted in our sales)
--   the store's copy (invoice # + "-C"): billed to the store, our price less the store's % off, HST on the rest, less the store's fee.
--     It is what accounting, HST, commissions, payroll and the Sales / Installs numbers use.
-- The store's copy is made and kept up to date from the customer's invoice and the store's numbers (by hand, or its payment history).
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS store_copy_of bigint;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS paid_at_store boolean NOT NULL DEFAULT false;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS store_copy_sig text;
ALTER TABLE public.invoice_lines ADD COLUMN IF NOT EXISTS store_adj boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS invoices_store_copy_of ON public.invoices (store_copy_of) WHERE store_copy_of IS NOT NULL;
ANALYZE public.invoices (store_copy_of, paid_at_store);

-- change a function in place: swap a piece of its text (skipped once done; stops the file if the text isn't there)
CREATE OR REPLACE FUNCTION public._patch_fn(p_fn text, p_old text, p_new text) RETURNS int LANGUAGE plpgsql SET search_path TO 'public' AS $function$
DECLARE s text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO s FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = p_fn LIMIT 1;
  IF s IS NULL THEN RAISE EXCEPTION 'patch %: no such function', p_fn; END IF;
  IF position(p_new in s) > 0 THEN RETURN 0; END IF;
  IF position(p_old in s) = 0 THEN RAISE EXCEPTION 'patch %: text not found: %', p_fn, left(p_old, 80); END IF;
  EXECUTE replace(s, p_old, p_new);
  RETURN 1;
END $function$;
REVOKE EXECUTE ON FUNCTION public._patch_fn(text, text, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._partner_pay(p_invoice bigint, p_partner bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i record; p record; t record; v_method text; v_card numeric; v_sub numeric; v_total numeric;
        v_d numeric; v_disc numeric := 0; v_after numeric; v_rate numeric; v_tax numeric; v_fee numeric := 0; v_cut numeric; v_pays numeric; v_calc numeric; v_st numeric; v_stn int; v_wh boolean;
        v_src bigint; v_c bigint; v_copy boolean; v_ss numeric; v_stax numeric; v_sfee numeric;
BEGIN
  -- the store's copy (-C) works from the customer's invoice it was made from
  SELECT coalesce(store_copy_of, id) INTO v_src FROM invoices WHERE id = p_invoice;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_copy := v_src <> p_invoice;
  SELECT min(id) INTO v_c FROM invoices WHERE store_copy_of = v_src AND status <> 'void';   -- (no ORDER BY ... LIMIT: that walks every invoice)
  SELECT subtotal, tax_total, total INTO i FROM invoices WHERE id = v_src;
  SELECT * INTO p FROM partners WHERE id = p_partner;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT method, card_fee, cut_pct, discount_pct, fee_amount INTO t FROM partner_invoice_terms WHERE invoice_id = coalesce(v_c, v_src);
  IF NOT FOUND THEN SELECT method, card_fee, cut_pct, discount_pct, fee_amount INTO t FROM partner_invoice_terms WHERE invoice_id = v_src; END IF;
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
    v_fee := coalesce(t.fee_amount, round(v_sub * coalesce(p.fee_pct, 10) / 100, 0) + coalesce(p.fee_flat, 0));
    v_calc := v_after + v_tax - v_fee - v_card;
  ELSE
    v_cut := coalesce(t.cut_pct, p.default_cut_pct, 0);
    v_calc := v_total - round(v_total * v_cut / 100, 2) - v_card;
  END IF;
  SELECT sum(l.net), count(*), sum(l.amount) FILTER (WHERE l.amount > 0), sum(l.hst + l.gst + l.qst) FILTER (WHERE l.amount > 0), -sum(l.amount) FILTER (WHERE l.amount < 0)
    INTO v_st, v_stn, v_ss, v_stax, v_sfee FROM partner_statement_lines l
    JOIN partner_statement_matches m ON m.partner_id = l.partner_id AND m.doc_no = l.doc_no
    WHERE m.invoice_id = v_src AND l.partner_id = p_partner;
  v_pays := CASE WHEN v_stn > 0 THEN v_st ELSE v_calc END;
  -- the store's own numbers, once its payment history is connected
  IF v_stn > 0 AND v_method = 'discount_fee' AND coalesce(v_ss, 0) > 0 THEN
    v_after := v_ss - coalesce(v_stax, 0); v_tax := coalesce(v_stax, 0); v_fee := coalesce(v_sfee, 0);
    v_disc := v_sub - v_after; v_d := CASE WHEN v_sub > 0 THEN round(v_disc / v_sub * 100, 2) END;
  END IF;
  -- a store water heater: the store's numbers are different every time, so they're typed in by hand
  -- (the water heater is most of the sale: a furnace + AC job that also has a tank isn't one)
  v_wh := v_sub > 0 AND coalesce((SELECT sum(x.line_total) FROM invoice_lines x WHERE x.invoice_id = v_src AND coalesce(x.line_total, 0) > 0
                  AND x.description ~* '(water heater|hot water tank|tankless|\mhwt\M|gallon|\m[0-9]+ ?gal\M)'), 0) >= v_sub * 0.5;
  RETURN jsonb_build_object('method', v_method, 'sale', v_sub, 'total', v_total, 'card', v_card,
    'cut_pct', CASE WHEN v_method = 'cut' THEN v_cut END,
    'discount_pct', CASE WHEN v_method = 'discount_fee' THEN v_d END, 'discount', v_disc, 'after', v_after, 'tax', v_tax, 'fee', v_fee,
    'calc', v_calc, 'pays', v_pays, 'keeps', v_total - v_pays - v_card,
    'from_statement', v_stn > 0, 'statement_diff', CASE WHEN v_stn > 0 THEN round(v_st - v_calc, 2) END,
    'own', t.method IS NOT NULL OR t.discount_pct IS NOT NULL OR t.fee_amount IS NOT NULL,
    'water_heater', v_wh, 'copy', v_copy, 'copy_id', v_c, 'src_id', v_src,
    'needs_hand', v_wh AND v_method = 'discount_fee' AND NOT coalesce(v_stn > 0, false) AND t.discount_pct IS NULL AND t.fee_amount IS NULL);
END $function$;


CREATE OR REPLACE FUNCTION public.partner_ledger(p_partner bigint, p_show text, p_from date, p_to date)
 RETURNS TABLE(invoice_id bigint, invoice_number text, invoice_date date, customer_id bigint, customer_name text, street text, city text, job_type text, total numeric, cut_pct numeric, cut_amount numeric, card_fee numeric, expected numeric, received numeric, still_due numeric, reference text, sent_on date, notes text, settled boolean, own_terms boolean, status text, account text, approval text, signed boolean, missing text[], supplier_amount numeric, supplier_name text, supplier_status text, pay jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  WITH p AS (SELECT * FROM partners WHERE id = p_partner),
  inv AS (
    SELECT i.*, j.job_type_id FROM invoices i JOIN jobs j ON j.id = i.job_id
    WHERE j.partner_id = p_partner AND NOT (SELECT bill_to_ok AND NOT customer_pays_partner FROM p)
      AND i.status NOT IN ('void', 'draft') AND i.total > 0
      AND NOT i.paid_at_store   -- the customer's copy of a store sale: the store's copy (-C) is the one that counts
      AND coalesce(i.look, '') <> 'reid' AND NOT (coalesce(i.look, '') = 'store' AND i.branding_partner_id IS DISTINCT FROM p_partner)
      AND NOT EXISTS (SELECT 1 FROM partners b WHERE b.id = i.bill_to_partner_id AND b.id <> p_partner AND b.bill_to_ok)
    UNION
    SELECT i.*, j.job_type_id FROM invoices i LEFT JOIN jobs j ON j.id = i.job_id
    WHERE i.bill_to_partner_id = p_partner AND i.status NOT IN ('void', 'draft') AND i.total > 0
      AND NOT i.paid_at_store
      AND (coalesce(i.look, '') <> 'reid' OR (SELECT bill_to_ok FROM p))),
  calc AS (
    SELECT i.id, i.invoice_number, i.invoice_date, coalesce(lc.id, c.id) AS cid, coalesce(lc.display_name, c.display_name) AS display_name, l.street, l.city, t.name AS jt, i.total,   -- the homeowner, even when billed to "Costco Inc."
           CASE WHEN p.bill_to_ok AND NOT p.customer_pays_partner THEN jsonb_build_object('method', 'cut', 'cut_pct', 0, 'card', 0, 'pays', i.total, 'keeps', 0)
                ELSE public._partner_pay(i.id, p.id) END AS pay,
           coalesce((SELECT sum(rl.amount) FROM partner_remittance_lines rl WHERE rl.invoice_id = i.id), 0)
             + CASE WHEN p.bill_to_ok AND NOT p.customer_pays_partner THEN coalesce(i.amount_paid, 0)
                    ELSE coalesce((SELECT sum(pa.amount) FROM payment_applications pa JOIN payments pm ON pm.id = pa.payment_id
                                   WHERE (pa.invoice_id = i.id OR pa.invoice_id = i.store_copy_of) AND pm.method = 'partner_remittance'), 0) END AS got,   -- store payments recorded on the customer's copy count on the store's
           pt.reference, pt.sent_on, pt.notes, pt.settled_at IS NOT NULL OR (p.bill_to_ok AND i.not_owed_reason IS NOT NULL) AS settled, pt.invoice_id IS NOT NULL AS own,
           i.partner_account, i.authorization_number, (i.signature_png IS NOT NULL OR i.signed_at IS NOT NULL) AS signed,
           CASE WHEN p.bill_to_ok AND i.bill_to_partner_id = p.id THEN public._inv_partner_missing(i.id) ELSE '{}'::text[] END AS missing,
           coalesce(sp.amount, 0) AS sup, sp.sname, sp.status AS sstatus
    FROM inv i CROSS JOIN p
    JOIN customers c ON c.id = i.customer_id
    LEFT JOIN locations l ON l.id = i.location_id
    LEFT JOIN customers lc ON lc.id = l.customer_id
    LEFT JOIN job_types t ON t.id = i.job_type_id
    LEFT JOIN partner_invoice_terms pt ON pt.invoice_id = i.id
    LEFT JOIN LATERAL (SELECT x.amount, s.name AS sname, x.status FROM third_party_supplier_payments x JOIN suppliers s ON s.id = x.supplier_id
                       WHERE x.invoice_id = i.id AND x.partner_id = p.id) sp ON true),
  m AS (SELECT *, coalesce((pay->>'pays')::numeric, total) - sup AS exp, coalesce((pay->>'keeps')::numeric, 0) AS keeps, coalesce((pay->>'card')::numeric, 0) AS card FROM calc)
  SELECT id, invoice_number, invoice_date, cid, display_name, street, city, jt, coalesce((pay->>'total')::numeric, total),   -- a store copy: the customer's price
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

-- take a store copy away (the invoice went back to the old way, was voided, ...): its terms and payments go back to the customer's invoice
CREATE OR REPLACE FUNCTION public._store_copy_drop(p_copy bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_src bigint;
BEGIN
  SELECT store_copy_of INTO v_src FROM invoices WHERE id = p_copy;
  IF v_src IS NULL THEN RETURN; END IF;
  UPDATE partner_remittance_lines SET invoice_id = v_src WHERE invoice_id = p_copy;
  IF EXISTS (SELECT 1 FROM partner_invoice_terms WHERE invoice_id = v_src) THEN DELETE FROM partner_invoice_terms WHERE invoice_id = p_copy;
  ELSE UPDATE partner_invoice_terms SET invoice_id = v_src WHERE invoice_id = p_copy; END IF;
  IF EXISTS (SELECT 1 FROM payment_applications WHERE invoice_id = p_copy) THEN
    UPDATE invoices SET status = 'void', void_reason = 'Store copy no longer needed' WHERE id = p_copy;
  ELSE
    DELETE FROM invoice_lines WHERE invoice_id = p_copy;
    DELETE FROM invoices WHERE id = p_copy;
  END IF;
  UPDATE invoices SET paid_at_store = false WHERE id = v_src AND NOT EXISTS (SELECT 1 FROM invoices x WHERE x.store_copy_of = v_src AND x.status <> 'void');
END $function$;

-- what's been paid on a store copy (store payments recorded on the partner page + any payments)
CREATE OR REPLACE FUNCTION public._store_copy_paid(p_copy bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v numeric;
BEGIN
  v := coalesce((SELECT sum(amount) FROM partner_remittance_lines WHERE invoice_id = p_copy), 0)
     + coalesce((SELECT sum(pa.amount) FROM payment_applications pa JOIN payments pm ON pm.id = pa.payment_id AND pm.status = 'succeeded' WHERE pa.invoice_id = p_copy), 0)
     + coalesce((SELECT sum(pa.amount) FROM invoices c JOIN payment_applications pa ON pa.invoice_id = c.store_copy_of JOIN payments pm ON pm.id = pa.payment_id AND pm.status = 'succeeded' AND pm.method = 'partner_remittance'
                 WHERE c.id = p_copy), 0);
  UPDATE invoices SET amount_paid = v,
         status = CASE WHEN status IN ('void', 'draft') THEN status WHEN total > 0 AND v >= total - 0.004 THEN 'paid' WHEN v > 0 THEN 'partially_paid' ELSE 'posted' END
   WHERE id = p_copy AND store_copy_of IS NOT NULL;
END $function$;

CREATE OR REPLACE FUNCTION public._prl_copy_paid() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF TG_OP <> 'INSERT' THEN PERFORM public._store_copy_paid(OLD.invoice_id); END IF;
  IF TG_OP <> 'DELETE' THEN PERFORM public._store_copy_paid(NEW.invoice_id); END IF;
  RETURN NULL;
END $function$;
DROP TRIGGER IF EXISTS prl_copy_paid ON public.partner_remittance_lines;
CREATE TRIGGER prl_copy_paid AFTER INSERT OR UPDATE OR DELETE ON public.partner_remittance_lines FOR EACH ROW EXECUTE FUNCTION public._prl_copy_paid();

-- make / refresh the store's copy of one customer invoice
CREATE OR REPLACE FUNCTION public._store_copy_build(p_src bigint, p_partner bigint) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE s invoices; p partners; v_c bigint; v_old text; v_sig text; v_pay jsonb; v_cust bigint; l record; v_map jsonb := '{}'; v_new bigint; v_seq int := 0;
        v_rate numeric; v_disc numeric; v_tot numeric; v_pays numeric;
BEGIN
  SELECT * INTO s FROM invoices WHERE id = p_src;
  SELECT * INTO p FROM partners WHERE id = p_partner;
  SELECT id, store_copy_sig INTO v_c, v_old FROM invoices WHERE id = (SELECT min(x.id) FROM invoices x WHERE x.store_copy_of = p_src AND x.status <> 'void');
  v_pay := public._partner_pay(p_src, p_partner);
  IF s.id IS NULL OR p.id IS NULL OR s.status IN ('void', 'draft') OR coalesce(s.total, 0) <= 0 OR s.store_copy_of IS NOT NULL
     OR coalesce(v_pay ->> 'method', '') <> 'discount_fee' THEN
    IF v_c IS NOT NULL THEN PERFORM public._store_copy_drop(v_c); END IF;
    RETURN NULL;
  END IF;
  v_sig := md5(concat_ws('|', 'v2', v_pay ->> 'discount', v_pay ->> 'fee', v_pay ->> 'tax', v_pay ->> 'pays', v_pay ->> 'card', s.invoice_date, s.job_id, s.location_id, s.subtotal, s.tax_total,
    (SELECT string_agg(concat_ws(',', x.id, x.item_id, x.description, x.quantity, x.unit_price, x.unit_cost, x.taxable, x.tax_rate_pct, x.kit_parent_line_id, x.hidden, x.no_charge, x.line_type), ';' ORDER BY x.id)
       FROM invoice_lines x WHERE x.invoice_id = p_src)));
  IF v_c IS NULL THEN
    v_cust := coalesce(p.customer_account_id, (SELECT c.id FROM customers c WHERE c.display_name ILIKE p.name || '%' ORDER BY c.id LIMIT 1), s.customer_id);
    INSERT INTO invoices (invoice_number, job_id, customer_id, location_id, business_unit_id, channel, bill_to_type, bill_to_partner_id, branding_partner_id, look,
                          status, invoice_date, payment_terms_days, collect_on_site, store_copy_of, notes, partner_account, po_number, authorization_number)
    VALUES (s.invoice_number || '-C', s.job_id, v_cust, s.location_id, s.business_unit_id, coalesce(s.channel, 'job'), 'partner', p.id, p.id, 'store',
            'posted', s.invoice_date, coalesce(p.payment_terms_days, 30), false, p_src, 'What ' || p.name || ' pays us for invoice ' || s.invoice_number,
            s.partner_account, s.po_number, s.authorization_number)
    RETURNING id INTO v_c;
    IF NOT EXISTS (SELECT 1 FROM partner_invoice_terms WHERE invoice_id = v_c) THEN UPDATE partner_invoice_terms SET invoice_id = v_c WHERE invoice_id = p_src; END IF;
    UPDATE partner_remittance_lines SET invoice_id = v_c WHERE invoice_id = p_src;
  ELSE
    UPDATE invoices SET job_id = s.job_id, location_id = s.location_id, invoice_date = s.invoice_date, business_unit_id = s.business_unit_id,
           partner_account = coalesce(s.partner_account, partner_account), invoice_number = s.invoice_number || '-C'
     WHERE id = v_c AND (job_id, location_id, invoice_date, business_unit_id, invoice_number) IS DISTINCT FROM (s.job_id, s.location_id, s.invoice_date, s.business_unit_id, s.invoice_number || '-C');
  END IF;
  UPDATE invoices SET paid_at_store = true WHERE id = p_src AND NOT paid_at_store;
  IF v_old IS DISTINCT FROM v_sig THEN
    DELETE FROM invoice_lines WHERE invoice_id = v_c;
    FOR l IN SELECT * FROM invoice_lines WHERE invoice_id = p_src ORDER BY (kit_parent_line_id IS NOT NULL), sequence, id LOOP
      v_seq := v_seq + 1;
      INSERT INTO invoice_lines (invoice_id, sequence, line_type, item_id, description, quantity, unit_price, unit_cost, supplied_by, taxable, tax_rate_pct,
                                 no_charge, regular_price, hidden, kit_parent_line_id, kit_each, cost_source)
      VALUES (v_c, v_seq, l.line_type, l.item_id, l.description, l.quantity, l.unit_price, l.unit_cost, l.supplied_by, l.taxable, l.tax_rate_pct,
              l.no_charge, l.regular_price, l.hidden, (v_map ->> l.kit_parent_line_id::text)::bigint, l.kit_each, l.cost_source)
      RETURNING id INTO v_new;
      v_map := v_map || jsonb_build_object(l.id::text, v_new);
    END LOOP;
    v_disc := (v_pay ->> 'discount')::numeric;
    v_rate := CASE WHEN coalesce(s.subtotal, 0) > 0 THEN round(coalesce(s.tax_total, 0) / s.subtotal * 100, 3) ELSE 0 END;
    IF coalesce(v_disc, 0) <> 0 THEN
      INSERT INTO invoice_lines (invoice_id, sequence, line_type, description, quantity, unit_price, unit_cost, taxable, tax_rate_pct, store_adj)
      VALUES (v_c, v_seq + 1, 'other', p.name || ' ' || trim_scale(round((v_pay ->> 'discount_pct')::numeric, 2)) || '% off our price', 1, -v_disc, 0, v_rate > 0, v_rate, true);
    END IF;
    -- the store's fee (and card fee); it also takes up any cents of rounding so the total is exactly what the store pays
    SELECT coalesce(sum(line_total), 0) + coalesce(sum(tax_amount), 0) INTO v_tot FROM invoice_lines WHERE invoice_id = v_c;
    v_pays := (v_pay ->> 'pays')::numeric;
    IF round(v_tot - v_pays, 2) <> 0 THEN
      INSERT INTO invoice_lines (invoice_id, sequence, line_type, description, quantity, unit_price, unit_cost, taxable, tax_rate_pct, store_adj)
      VALUES (v_c, v_seq + 2, 'other', p.name || ' fee' || CASE WHEN coalesce((v_pay ->> 'card')::numeric, 0) > 0 THEN ' and gift card fee' ELSE '' END
              || CASE WHEN (v_pay ->> 'from_statement')::boolean THEN ' (from ' || p.name || '''s payment)' ELSE '' END, 1, -round(v_tot - v_pays, 2), 0, false, 0, true);
    END IF;
    UPDATE invoices SET store_copy_sig = v_sig WHERE id = v_c;
  END IF;
  PERFORM public._store_copy_paid(v_c);
  RETURN v_c;
END $function$;

-- every invoice the store pays us for (the same ones its partner page lists)
CREATE OR REPLACE FUNCTION public._store_copies_sync(p_partner bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE r record; v_n int := 0; v_on boolean;
BEGIN
  SELECT pay_method = 'discount_fee' AND customer_pays_partner INTO v_on FROM partners WHERE id = p_partner;
  FOR r IN
    WITH src AS (
      SELECT i.id FROM invoices i JOIN jobs j ON j.id = i.job_id
      WHERE j.partner_id = p_partner AND i.store_copy_of IS NULL AND i.status NOT IN ('void', 'draft') AND i.total > 0
        AND coalesce(i.look, '') <> 'reid' AND NOT (coalesce(i.look, '') = 'store' AND i.branding_partner_id IS DISTINCT FROM p_partner)
        AND NOT EXISTS (SELECT 1 FROM partners b WHERE b.id = i.bill_to_partner_id AND b.id <> p_partner AND b.bill_to_ok)
      UNION
      SELECT i.id FROM invoices i WHERE i.bill_to_partner_id = p_partner AND i.store_copy_of IS NULL AND i.status NOT IN ('void', 'draft') AND i.total > 0
        AND coalesce(i.look, '') <> 'reid')
    SELECT src.id, true AS keep FROM src WHERE coalesce(v_on, false)
    UNION ALL
    SELECT x.store_copy_of, false FROM invoices x WHERE x.store_copy_of IS NOT NULL AND x.bill_to_partner_id = p_partner AND x.status <> 'void'
      AND (NOT coalesce(v_on, false) OR x.store_copy_of NOT IN (SELECT id FROM src))
  LOOP
    IF r.keep THEN PERFORM public._store_copy_build(r.id, p_partner); v_n := v_n + 1;
    ELSE PERFORM public._store_copy_drop(x.id) FROM invoices x WHERE x.store_copy_of = r.id AND x.bill_to_partner_id = p_partner AND x.status <> 'void'; END IF;
  END LOOP;
  RETURN v_n;
END $function$;

CREATE OR REPLACE FUNCTION public.store_copies_sync(p_partner bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._can_partner_pay() THEN RETURN 0; END IF;
  RETURN public._store_copies_sync(p_partner);
END $function$;
REVOKE EXECUTE ON FUNCTION public._store_copy_drop(bigint), public._store_copy_paid(bigint), public._store_copy_build(bigint, bigint), public._store_copies_sync(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.store_copies_sync(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_copies_sync(bigint) TO authenticated;

-- commission: the customer's copy of a store sale doesn't count; the store's copy counts at what the store pays us before HST
-- (each line's own commission %, scaled down by what the store takes off)
CREATE OR REPLACE FUNCTION public._comm_job(p_emp bigint, p_job bigint) RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v numeric; n int;
BEGIN
  IF p_emp IS NULL OR p_job IS NULL THEN RETURN NULL; END IF;
  WITH iv AS (
    SELECT i.id, CASE WHEN i.store_copy_of IS NOT NULL
                      THEN i.subtotal / nullif((SELECT sum(y.line_total) FROM invoice_lines y WHERE y.invoice_id = i.id AND NOT y.store_adj AND y.kit_parent_line_id IS NULL), 0)
                      ELSE 1 END AS f
    FROM invoices i WHERE i.job_id = p_job AND i.status NOT IN ('void', 'draft') AND NOT i.paid_at_store)
  SELECT count(*), sum(x.line_total * coalesce(iv.f, 1) * coalesce(CASE WHEN x.item_id IS NULL THEN (SELECT pct FROM commission_rates WHERE employee_id = p_emp) ELSE public._comm_pct(p_emp, x.item_id) END, 0) / 100)
    INTO n, v FROM invoice_lines x JOIN iv ON iv.id = x.invoice_id
   WHERE x.kit_parent_line_id IS NULL AND NOT x.store_adj;
  IF n = 0 THEN
    SELECT count(*), sum(x.line_total * coalesce(CASE WHEN x.item_id IS NULL THEN (SELECT pct FROM commission_rates WHERE employee_id = p_emp) ELSE public._comm_pct(p_emp, x.item_id) END, 0) / 100)
      INTO n, v FROM invoice_lines x JOIN invoices i ON i.id = x.invoice_id
     WHERE i.job_id = p_job AND i.status = 'draft' AND x.kit_parent_line_id IS NULL;
  END IF;
  IF n = 0 THEN
    SELECT count(*), sum(x.line_total * coalesce(CASE WHEN x.item_id IS NULL THEN (SELECT pct FROM commission_rates WHERE employee_id = p_emp) ELSE public._comm_pct(p_emp, x.item_id) END, 0) / 100)
      INTO n, v FROM estimate_lines x JOIN estimates e ON e.accepted_option_id = x.estimate_option_id
      JOIN jobs j ON j.id = p_job AND (e.id = j.sold_estimate_id OR e.id = j.from_estimate_id)
     WHERE x.parent_line_id IS NULL;
  END IF;
  RETURN CASE WHEN n > 0 THEN round(v, 2) END;
END $function$;
REVOKE EXECUTE ON FUNCTION public._comm_job(bigint, bigint) FROM PUBLIC, anon, authenticated;

-- everything else that adds up invoices: count the store's copy, not the customer's
SELECT public._patch_fn('gl_report', $o$WHERE i.status NOT IN ('void', 'draft') AND i.invoice_date BETWEEN p_from AND p_to)$o$,
                                     $n$WHERE i.status NOT IN ('void', 'draft') AND NOT i.paid_at_store AND i.invoice_date BETWEEN p_from AND p_to)$n$);
SELECT public._patch_fn('gl_report', $o$LATERAL public.partner_ledger(p.id, 'all', p_from, p_to) pl WHERE p.customer_pays_partner)$o$,
                                     $n$LATERAL public.partner_ledger(p.id, 'all', p_from, p_to) pl WHERE p.customer_pays_partner AND NOT coalesce((pl.pay ->> 'copy')::boolean, false))$n$);
SELECT public._patch_fn('tax_summary', $o$WHERE i.status NOT IN ('void', 'draft') AND i.invoice_date BETWEEN p_from AND p_to)$o$,
                                       $n$WHERE i.status NOT IN ('void', 'draft') AND NOT i.paid_at_store AND i.invoice_date BETWEEN p_from AND p_to)$n$);
SELECT public._patch_fn('tax_periods', $o$FROM invoices WHERE status NOT IN ('void', 'draft') AND invoice_date BETWEEN$o$,
                                       $n$FROM invoices WHERE status NOT IN ('void', 'draft') AND NOT paid_at_store AND invoice_date BETWEEN$n$);
SELECT public._patch_fn('install_list', $o$FROM invoices i WHERE i.job_id = j.id AND i.status NOT IN ('void', 'draft')$o$,
                                        $n$FROM invoices i WHERE i.job_id = j.id AND i.status NOT IN ('void', 'draft') AND NOT i.paid_at_store$n$);
SELECT public._patch_fn('_sales_hist_inst', $o$WHERE i.job_id IN (SELECT un.id FROM un) AND i.status NOT IN ('void', 'draft')$o$,
                                            $n$WHERE i.job_id IN (SELECT un.id FROM un) AND i.status NOT IN ('void', 'draft') AND NOT i.paid_at_store$n$);
SELECT public._patch_fn('my_day', $o$AND i.status NOT IN ('void', 'draft') AND i.not_owed_reason IS NULL)$o$,
                                  $n$AND i.status NOT IN ('void', 'draft') AND i.not_owed_reason IS NULL AND NOT i.paid_at_store)$n$);
SELECT public._patch_fn('missing_costs', $o$AND i.status NOT IN ('void', 'draft') AND i.invoice_date BETWEEN p_from AND p_to)$o$,
                                         $n$AND i.status NOT IN ('void', 'draft') AND i.store_copy_of IS NULL AND i.invoice_date BETWEEN p_from AND p_to)$n$);
SELECT public._patch_fn('missing_costs', $o$WHERE x.cost_source = 'price book' AND i.invoice_date$o$, $n$WHERE x.cost_source = 'price book' AND i.store_copy_of IS NULL AND i.invoice_date$n$);
SELECT public._patch_fn('pb_item_stock', $o$JOIN invoices i ON i.id = il.invoice_id$o$, $n$JOIN invoices i ON i.id = il.invoice_id AND i.store_copy_of IS NULL$n$);
SELECT public._patch_fn('pb_list', $o$JOIN invoices i ON i.id = il.invoice_id$o$, $n$JOIN invoices i ON i.id = il.invoice_id AND i.store_copy_of IS NULL$n$);
SELECT public._patch_fn('inv_editor', $o$'can_edit', i.st_id IS NULL AND$o$, $n$'can_edit', i.st_id IS NULL AND i.store_copy_of IS NULL AND$n$);
SELECT public._patch_fn('_inv_for_edit', $o$IF i.st_id IS NOT NULL THEN RAISE EXCEPTION$o$,
  $n$IF i.store_copy_of IS NOT NULL THEN RAISE EXCEPTION 'This is the store''s copy. It''s made from the customer''s invoice and the store''s numbers on the Partners page.'; END IF;
  IF i.st_id IS NOT NULL THEN RAISE EXCEPTION$n$);
SELECT public._patch_fn('est_sold_invoice', $o$SELECT id INTO v_id FROM invoices WHERE job_id = ij.id AND status <> 'void' ORDER BY id DESC LIMIT 1;$o$,
                                            $n$SELECT id INTO v_id FROM invoices WHERE job_id = ij.id AND status <> 'void' AND store_copy_of IS NULL ORDER BY id DESC LIMIT 1;$n$);
SELECT public._patch_fn('partner_statement_match', $o$        AND i.subtotal > 0$o$, $n$        AND i.subtotal > 0 AND i.store_copy_of IS NULL$n$);
SELECT public._patch_fn('partner_statement_set', $o$WHERE invoice_number = v_num AND subtotal > 0$o$, $n$WHERE invoice_number = v_num AND subtotal > 0 AND store_copy_of IS NULL$n$);

-- keep every store copy up to date (this file runs with each sync)
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT id FROM partners WHERE customer_pays_partner AND (pay_method = 'discount_fee' OR EXISTS (SELECT 1 FROM invoices x WHERE x.store_copy_of IS NOT NULL AND x.bill_to_partner_id = partners.id)) LOOP
    PERFORM public._store_copies_sync(r.id);
  END LOOP;
END $$;
NOTIFY pgrst, 'reload schema';

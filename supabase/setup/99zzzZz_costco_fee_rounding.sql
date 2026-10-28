-- Costco's fee is rounded to the whole dollar before the $1.50 (6589: 658.90 -> 659 + 1.50 = 660.50).
-- Costco water heaters: Costco's % off and fee are different every time, so the partner page asks for them by hand.
CREATE OR REPLACE FUNCTION public._partner_pay(p_invoice bigint, p_partner bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i record; p record; t record; v_method text; v_card numeric; v_sub numeric; v_total numeric;
        v_d numeric; v_disc numeric := 0; v_after numeric; v_rate numeric; v_tax numeric; v_fee numeric := 0; v_cut numeric; v_pays numeric; v_calc numeric; v_st numeric; v_stn int; v_wh boolean;
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
    v_fee := coalesce(t.fee_amount, round(v_sub * coalesce(p.fee_pct, 10) / 100, 0) + coalesce(p.fee_flat, 0));
    v_calc := v_after + v_tax - v_fee - v_card;
  ELSE
    v_cut := coalesce(t.cut_pct, p.default_cut_pct, 0);
    v_calc := v_total - round(v_total * v_cut / 100, 2) - v_card;
  END IF;
  SELECT sum(l.net), count(*) INTO v_st, v_stn FROM partner_statement_lines l
    JOIN partner_statement_matches m ON m.partner_id = l.partner_id AND m.doc_no = l.doc_no
    WHERE m.invoice_id = p_invoice AND l.partner_id = p_partner;
  v_pays := CASE WHEN v_stn > 0 THEN v_st ELSE v_calc END;
  -- a store water heater: the store's numbers are different every time, so they're typed in by hand
  -- (the water heater is most of the sale: a furnace + AC job that also has a tank isn't one)
  v_wh := v_sub > 0 AND coalesce((SELECT sum(x.line_total) FROM invoice_lines x WHERE x.invoice_id = p_invoice AND coalesce(x.line_total, 0) > 0
                  AND x.description ~* '(water heater|hot water tank|tankless|\mhwt\M|gallon|\m[0-9]+ ?gal\M)'), 0) >= v_sub * 0.5;
  RETURN jsonb_build_object('method', v_method, 'sale', v_sub, 'total', v_total, 'card', v_card,
    'cut_pct', CASE WHEN v_method = 'cut' THEN v_cut END,
    'discount_pct', CASE WHEN v_method = 'discount_fee' THEN v_d END, 'discount', v_disc, 'after', v_after, 'tax', v_tax, 'fee', v_fee,
    'calc', v_calc, 'pays', v_pays, 'keeps', v_total - v_pays - v_card,
    'from_statement', v_stn > 0, 'statement_diff', CASE WHEN v_stn > 0 THEN round(v_st - v_calc, 2) END,
    'own', t.method IS NOT NULL OR t.discount_pct IS NOT NULL OR t.fee_amount IS NOT NULL,
    'water_heater', v_wh,
    'needs_hand', v_wh AND v_method = 'discount_fee' AND NOT coalesce(v_stn > 0, false) AND t.discount_pct IS NULL AND t.fee_amount IS NULL);
END $function$;

NOTIFY pgrst, 'reload schema';

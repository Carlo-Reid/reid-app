-- ServiceTitan's own tax on each of its invoices (tax_st), kept as it sends it. An invoice from ServiceTitan that isn't edited in the app
-- uses that tax as is (ServiceTitan decides per discount whether it comes off before or after tax), so a paid invoice never shows a balance
-- just because the app worked the tax out differently (e.g. 15054715: $821.15, not $1,103.70).
-- Invoices made or edited in the app work the tax out themselves: after discounts (sync/extra/216).
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS tax_st numeric(12,2);

CREATE OR REPLACE FUNCTION public.recalc_invoice(p_invoice bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_inv invoices; v_tax numeric;
BEGIN
  SELECT * INTO v_inv FROM invoices WHERE id = p_invoice; IF v_inv.id IS NULL THEN RETURN; END IF;
  v_tax := CASE WHEN v_inv.tax_st IS NOT NULL AND v_inv.app_edited_at IS NULL AND v_inv.st_id IS NOT NULL THEN v_inv.tax_st
                WHEN v_inv.st_id IS NOT NULL AND v_inv.app_edited_at IS NULL THEN (SELECT coalesce(sum(tax_amount), 0) FROM invoice_lines WHERE invoice_id = p_invoice)   -- as before until ServiceTitan's figure is in
                ELSE public._inv_tax(p_invoice) END;
  UPDATE invoices i SET
    subtotal  = coalesce(x.sub, 0),
    tax_total = v_tax,
    total     = coalesce(x.sub, 0) + v_tax,
    amount_paid = coalesce(p.paid, 0),
    status = CASE
      WHEN i.status IN ('draft','void') THEN i.status
      WHEN coalesce(p.paid,0) >= coalesce(x.sub,0) + v_tax AND coalesce(x.sub,0) + v_tax > 0 THEN 'paid'
      WHEN coalesce(p.paid,0) > 0 THEN 'partially_paid'
      WHEN i.status IN ('paid','partially_paid') THEN 'posted'
      ELSE i.status END
  FROM (SELECT sum(line_total) sub FROM invoice_lines WHERE invoice_id = p_invoice) x,
       (SELECT sum(pa.amount) paid FROM payment_applications pa
          JOIN payments py ON py.id = pa.payment_id AND py.status = 'succeeded'
        WHERE pa.invoice_id = p_invoice) p
  WHERE i.id = p_invoice;
END $$;
DROP FUNCTION IF EXISTS public.tax_fix_preview();
NOTIFY pgrst, 'reload schema';

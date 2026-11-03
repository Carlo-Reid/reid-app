-- Bank payment matching: each year's run keeps its own links (so a January deposit for a December payment isn't lost between runs)
ALTER TABLE public.bank_invoice_links ADD COLUMN IF NOT EXISTS run_year int;
DO $do$
DECLARE src text := pg_get_functiondef('public.bank_pay_match(text, integer)'::regprocedure);
BEGIN
  IF src LIKE '%run_year%' THEN RETURN; END IF;
  src := replace(src, $a$AND NOT EXISTS (SELECT 1 FROM bank_invoice_links k WHERE k.bank_id = b.id AND (k.how IS NULL OR k.how <> p_kind))$a$,
                      $a$AND NOT EXISTS (SELECT 1 FROM bank_invoice_links k WHERE k.bank_id = b.id AND NOT (k.how = p_kind AND k.run_year = p_year))$a$);
  src := replace(src, $a$DELETE FROM bank_invoice_links k USING bank_transactions b WHERE b.id = k.bank_id AND k.how = p_kind AND k.partner_id IS NULL AND b.txn_date BETWEEN v_from AND v_to + 30
    AND NOT EXISTS (SELECT 1 FROM _pd WHERE _pd.id = k.bank_id AND _pd.done IS NULL AND false);$a$,
                      $a$DELETE FROM bank_invoice_links k WHERE k.how = p_kind AND k.run_year = p_year;$a$);
  src := replace(src, $a$INSERT INTO bank_invoice_links (bank_id, invoice_id, amount, partner_id, how)
    SELECT p.bank, pa.invoice_id, sum(pa.amount), NULL, p_kind FROM _pp p$a$, $a$INSERT INTO bank_invoice_links (bank_id, invoice_id, amount, partner_id, how, run_year)
    SELECT p.bank, pa.invoice_id, sum(pa.amount), NULL, p_kind, p_year FROM _pp p$a$);
  IF (length(src) - length(replace(src, 'run_year', ''))) / 8 < 3 THEN RAISE EXCEPTION 'bank_pay_match: anchors not found'; END IF;
  EXECUTE src;
END $do$;
NOTIFY pgrst, 'reload schema';

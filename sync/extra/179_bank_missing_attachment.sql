-- (re-made on every sync, after 140 and 167 rebuild bank_list)
-- Bank transactions: "Missing an attachment": the lines with nothing tied to them (no invoice, supplier invoice, file, transfer or vehicle),
-- picked like a kind (p_cat = '__noatt'), with how many there are
DO $do$
DECLARE src text; cond text := $c$NOT EXISTS (SELECT 1 FROM bank_invoice_links k WHERE k.bank_id = f.id) AND NOT EXISTS (SELECT 1 FROM bank_files k WHERE k.bank_id = f.id)
    AND NOT EXISTS (SELECT 1 FROM bank_sinv_links k WHERE k.bank_id = f.id) AND NOT EXISTS (SELECT 1 FROM bank_transfer_links k WHERE k.a_id = f.id OR k.b_id = f.id)
    AND NOT EXISTS (SELECT 1 FROM bank_vehicle_links k WHERE k.bank_id = f.id)$c$;
BEGIN
  IF to_regprocedure('public.bank_list(text, date, date, text, text, integer, integer, text, boolean)') IS NULL THEN RETURN; END IF;
  src := pg_get_functiondef('public.bank_list(text, date, date, text, text, integer, integer, text, boolean)'::regprocedure);
  IF src LIKE '%__noatt%' THEN RETURN; END IF;
  src := replace(src, 'g AS (SELECT * FROM f WHERE p_cat IS NULL OR cat = p_cat)',
    'g AS (SELECT * FROM f WHERE p_cat IS NULL OR (p_cat = ''__noatt'' AND ' || cond || ') OR cat = p_cat)');
  src := replace(src, $a$'count', (SELECT count(*) FROM g),$a$, $a$'count', (SELECT count(*) FROM g), 'noatt', (SELECT count(*) FROM f WHERE $a$ || cond || '),');
  IF src NOT LIKE '%p_cat = ''__noatt''%' OR src NOT LIKE '%''noatt''%' THEN RAISE EXCEPTION 'bank_list: anchors not found'; END IF;
  EXECUTE src;
END $do$;
NOTIFY pgrst, 'reload schema';

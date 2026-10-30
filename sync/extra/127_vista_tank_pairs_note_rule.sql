-- Vista tank pairs: the tank invoice is the one whose amounts are all on "Note: …" lines (the supplier's tank amount);
-- the labour invoice is another invoice on the same job with a real line on it (the closest date wins)
DO $$ DECLARE s text; BEGIN
  SELECT pg_get_functiondef('public.vista_tank_pairs(bigint, text)'::regprocedure) INTO s;
  s := replace(s, 'has_item AS (SELECT DISTINCT il.invoice_id FROM invoice_lines il JOIN v ON v.id = il.invoice_id WHERE il.item_id IS NOT NULL AND coalesce(il.unit_price, 0) > 0),',
    'has_item AS (SELECT DISTINCT il.invoice_id FROM invoice_lines il JOIN v ON v.id = il.invoice_id WHERE coalesce(il.line_total, 0) > 0 AND il.description !~* ''^\s*note\s*:''),
  has_note AS (SELECT DISTINCT il.invoice_id FROM invoice_lines il JOIN v ON v.id = il.invoice_id WHERE coalesce(il.line_total, 0) > 0 AND il.description ~* ''^\s*note\s*:''),');
  s := replace(s, 'WHERE tk.id NOT IN (SELECT invoice_id FROM has_item) AND lb.id IN (SELECT invoice_id FROM has_item)',
                  'WHERE tk.id IN (SELECT invoice_id FROM has_note) AND tk.id NOT IN (SELECT invoice_id FROM has_item) AND lb.id IN (SELECT invoice_id FROM has_item)');
  EXECUTE s;
END $$;
NOTIFY pgrst, 'reload schema';

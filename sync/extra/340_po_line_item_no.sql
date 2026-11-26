-- A P.O. line also answers its item number (our price book code) and model, so ServiceTitan's P.O. lines
-- (which only have words) show the part's number too (Carlo, Nov 25, 2026). Patches po_full_get and po_detail in place.
DO $do$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.po_full_get(bigint)'::regprocedure);
  IF position('''item_sku''' in d) = 0 AND position('''received'', l.quantity_received,' in d) > 0 THEN
    d := replace(d, '''received'', l.quantity_received,',
      '''received'', l.quantity_received, ''item_id'', l.item_id, ''item_sku'', (SELECT pi.sku FROM pricebook_items pi WHERE pi.id = l.item_id), ''item_model'', (SELECT pi.model_number FROM pricebook_items pi WHERE pi.id = l.item_id),');
    EXECUTE d;
  END IF;
  d := pg_get_functiondef('public.po_detail(bigint)'::regprocedure);
  IF position('''item_sku''' in d) = 0 AND position('''received'', x.quantity_received)' in d) > 0 THEN
    d := replace(d, '''received'', x.quantity_received)',
      '''received'', x.quantity_received, ''item_id'', x.item_id, ''item_sku'', (SELECT pi.sku FROM pricebook_items pi WHERE pi.id = x.item_id), ''item_model'', (SELECT pi.model_number FROM pricebook_items pi WHERE pi.id = x.item_id))');
    EXECUTE d;
  END IF;
END $do$;

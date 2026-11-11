-- The item page's "Where:" squares show the tech's picture (Carlo, Nov 10: "on the item page add the tech pictures to the buttons").
-- pb_item_stock's list of places now also says whose truck each place is (stock_locations.assigned_employee_id), so the app can
-- put that person's Staff page picture on the square. In-place patch, done once. Safe to run more than once.
DO $do$
DECLARE d text; a text := '''type'', sl.location_type, ''qty'', v.qty_on_hand)'; b text := '''type'', sl.location_type, ''emp'', sl.assigned_employee_id, ''qty'', v.qty_on_hand)';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'pb_item_stock';
  IF d IS NULL THEN RAISE NOTICE 'pb_item_stock: not found'; RETURN; END IF;
  IF position(b in d) > 0 THEN RETURN; END IF;
  IF position(a in d) = 0 THEN RAISE NOTICE 'pb_item_stock: the words to change were not found'; RETURN; END IF;
  EXECUTE replace(d, a, b);
END $do$;

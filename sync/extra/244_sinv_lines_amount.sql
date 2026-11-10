-- Supplier invoices list: lines_amount = the invoice's own lines added up (Carlo, Nov 10, 2026).
-- A pick ticket is saved with $0 and no subtotal, so the list said "Under the PO by $1,803.00" while every line matched the PO (C440593).
-- The list now also gives the lines' total, and the app uses it as the before-tax amount when the invoice has no dollar amount of its own.
CREATE OR REPLACE FUNCTION public._sinv_lines_amount(p_lines jsonb) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT round(sum(CASE
      WHEN (x ->> 'net_amount') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (x ->> 'net_amount')::numeric
      WHEN (x ->> 'unit_price') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (x ->> 'unit_price')::numeric
           * CASE WHEN coalesce(x ->> 'shipped', x ->> 'ordered') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN coalesce(x ->> 'shipped', x ->> 'ordered')::numeric ELSE 1 END
           * (1 - CASE WHEN (x ->> 'discount') ~ '^[0-9]+(\.[0-9]+)?$' THEN (x ->> 'discount')::numeric ELSE 0 END / 100) END), 2)
  FROM (SELECT DISTINCT ON (x ->> 'code', x ->> 'description', coalesce(x ->> 'shipped', x ->> 'ordered'), x ->> 'unit_price', x ->> 'net_amount') x   -- a line read twice off the scan counts once
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END) x) u
$$;
-- add the column to supplier_invoices_list as it stands (whatever earlier file last defined it)
DO $do$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'supplier_invoices_list';
  IF d IS NULL OR position('lines_amount' in d) > 0 THEN RETURN; END IF;
  IF position('jsonb_array_length(i.lines) AS line_count,' in d) = 0 THEN RAISE NOTICE 'supplier_invoices_list: line_count not found, lines_amount not added'; RETURN; END IF;
  EXECUTE replace(d, 'jsonb_array_length(i.lines) AS line_count,', 'jsonb_array_length(i.lines) AS line_count, public._sinv_lines_amount(i.lines) AS lines_amount,');
END $do$;

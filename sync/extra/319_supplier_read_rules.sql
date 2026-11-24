-- Supplier invoices: each supplier has its own rules for how its papers are read (Carlo, Nov 18, 2026: "each supplier has its own invoices and I want
-- to fix how they are read, each one should have its own set of rules it follows… have a box in each section called rules where we can keep them,
-- add more or change them if needed"). A rule says what to pick up (the purchase date, the order number, the P.O. number, the due date, the amounts)
-- and where it is printed on the supplier's page (a box, in percent of the page). The reader in the app reads that box and uses what it finds.
-- Also new: a due date on a supplier invoice.
ALTER TABLE public.supplier_invoices ADD COLUMN IF NOT EXISTS due_date date;

CREATE TABLE IF NOT EXISTS public.supplier_read_rules (
  supplier_id bigint PRIMARY KEY,
  rules jsonb NOT NULL DEFAULT '[]'::jsonb,     -- [{id, f, x, y, w, h, fmt, g?}]: f = date | number | po | due | subtotal | hst | total | page; x, y, w, h in percent of the page
  notes text,                                    -- plain words: anything else this supplier's papers should do
  updated_by bigint, updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.supplier_read_rules ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.supplier_rules_get(p_supplier bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN NOT (public._sinv_can_edit() OR public._can_see_costs()) THEN '{}'::jsonb ELSE jsonb_build_object('can_edit', public._sinv_can_edit(),
    'by', coalesce((SELECT jsonb_object_agg(r.supplier_id::text, jsonb_build_object('rules', r.rules, 'notes', coalesce(r.notes, ''), 'at', r.updated_at))
                    FROM supplier_read_rules r WHERE p_supplier IS NULL OR r.supplier_id = p_supplier), '{}'::jsonb)) END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_rules_get(bigint) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.supplier_rules_get(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.supplier_rules_set(p_supplier bigint, p_rules jsonb, p_notes text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v jsonb := '[]'::jsonb; e jsonb; f text; n int := 0;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier) THEN RAISE EXCEPTION 'That supplier is gone'; END IF;
  IF jsonb_typeof(coalesce(p_rules, '[]'::jsonb)) <> 'array' THEN RAISE EXCEPTION 'The rules are not a list'; END IF;
  FOR e IN SELECT * FROM jsonb_array_elements(coalesce(p_rules, '[]'::jsonb)) LOOP
    f := e->>'f'; n := n + 1;
    IF n > 30 THEN RAISE EXCEPTION 'That is too many rules (30 at most)'; END IF;
    IF f IS NULL OR f NOT IN ('date', 'number', 'po', 'due', 'subtotal', 'hst', 'total', 'page') THEN RAISE EXCEPTION 'Rule %: pick what it picks up', n; END IF;
    IF NOT ((e->>'x')::numeric BETWEEN 0 AND 100 AND (e->>'y')::numeric BETWEEN 0 AND 100 AND (e->>'w')::numeric BETWEEN 0.5 AND 100 AND (e->>'h')::numeric BETWEEN 0.5 AND 100) THEN
      RAISE EXCEPTION 'Rule %: draw its box on the page', n; END IF;
    v := v || jsonb_build_array(jsonb_build_object('id', coalesce(nullif(e->>'id', ''), 'r' || n), 'f', f,
      'x', round((e->>'x')::numeric, 2), 'y', round((e->>'y')::numeric, 2), 'w', round((e->>'w')::numeric, 2), 'h', round((e->>'h')::numeric, 2),
      'fmt', CASE WHEN e->>'fmt' = 'dmy' THEN 'dmy' ELSE 'mdy' END)
      -- g = which kind of the supplier's papers the rule is for (empty or 'Invoice' = their invoice; Boone also has 'Packing slip / Sales order')
      || CASE WHEN nullif(btrim(coalesce(e->>'g', '')), '') IS NULL OR btrim(e->>'g') = 'Invoice' THEN '{}'::jsonb ELSE jsonb_build_object('g', left(btrim(e->>'g'), 40)) END);
  END LOOP;
  INSERT INTO supplier_read_rules (supplier_id, rules, notes, updated_by, updated_at)
  VALUES (p_supplier, v, nullif(btrim(left(coalesce(p_notes, ''), 4000)), ''), public.current_app_user_id(), now())
  ON CONFLICT (supplier_id) DO UPDATE SET rules = EXCLUDED.rules, notes = EXCLUDED.notes, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_read_rules', p_supplier, 'update', public.current_app_user_id(), jsonb_build_object('rules', v, 'notes', p_notes));
  RETURN jsonb_build_object('rules', v);
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_rules_set(bigint, jsonb, text) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.supplier_rules_set(bigint, jsonb, text) TO authenticated;

-- the due date of one supplier invoice (null takes it off)
CREATE OR REPLACE FUNCTION public.supplier_invoice_due_set(p_id bigint, p_due date) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF p_due IS NOT NULL AND (p_due < DATE '2015-01-01' OR p_due > current_date + 730) THEN RAISE EXCEPTION 'That due date does not look right'; END IF;
  UPDATE supplier_invoices SET due_date = p_due, updated_at = now() WHERE id = p_id AND due_date IS DISTINCT FROM p_due;
  IF FOUND THEN INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
    VALUES ('supplier_invoices', p_id, 'update', public.current_app_user_id(), jsonb_build_object('due_date', p_due)); END IF;
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_due_set(bigint, date) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.supplier_invoice_due_set(bigint, date) TO authenticated;

-- the due dates of a supplier's invoices, for the list: { invoice id: date }
CREATE OR REPLACE FUNCTION public.supplier_invoice_dues(p_supplier bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN NOT (public._sinv_can_edit() OR public._can_see_costs()) THEN '{}'::jsonb ELSE
    coalesce((SELECT jsonb_object_agg(i.id::text, i.due_date) FROM supplier_invoices i WHERE i.due_date IS NOT NULL AND (p_supplier IS NULL OR i.supplier_id = p_supplier)), '{}'::jsonb) END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_dues(bigint) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.supplier_invoice_dues(bigint) TO authenticated;

-- Boone's first rules (measured on invoice C399102, Nov 18, 2026). Only put in when Boone has none, so what a person changes in the app stays.
INSERT INTO public.supplier_read_rules (supplier_id, rules, notes)
SELECT s.id, '[
  {"id":"b1","f":"date","x":55,"y":25,"w":21,"h":6.2,"fmt":"mdy"},
  {"id":"b2","f":"number","x":77,"y":25,"w":20,"h":6.2,"fmt":"mdy"},
  {"id":"b3","f":"po","x":4,"y":35.4,"w":28,"h":3.4,"fmt":"mdy"},
  {"id":"b4","f":"due","x":83,"y":35.4,"w":14,"h":3.4,"fmt":"mdy"},
  {"id":"b5","f":"subtotal","x":82,"y":79.6,"w":15,"h":3.2,"fmt":"mdy"},
  {"id":"b6","f":"hst","x":82,"y":83.6,"w":15,"h":3.4,"fmt":"mdy"},
  {"id":"b7","f":"total","x":82,"y":89.6,"w":15,"h":3.6,"fmt":"mdy"}]'::jsonb, NULL
FROM public.suppliers s WHERE s.id = 1 AND s.name ILIKE 'Boone%'
ON CONFLICT (supplier_id) DO NOTHING;

-- Boone's second kind of paper: its "Sales order / Packing slip" (Carlo, Nov 18, 2026; measured on packing slip C312797, both pages).
-- Added once, only when Boone's rules have no packing slip rule yet, so what a person changes in the app stays.
UPDATE public.supplier_read_rules r SET rules = r.rules || '[
  {"id":"s1","f":"number","g":"Packing slip / Sales order","x":73,"y":15.8,"w":24,"h":2.3,"fmt":"mdy"},
  {"id":"s2","f":"date","g":"Packing slip / Sales order","x":73,"y":17.3,"w":24,"h":2.3,"fmt":"mdy"},
  {"id":"s3","f":"po","g":"Packing slip / Sales order","x":4,"y":31.3,"w":24,"h":3.2,"fmt":"mdy"}]'::jsonb, updated_at = now()
WHERE r.supplier_id = 1 AND EXISTS (SELECT 1 FROM public.suppliers s WHERE s.id = 1 AND s.name ILIKE 'Boone%')
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r.rules) e WHERE coalesce(e->>'g', '') ~* 'slip' OR e->>'id' IN ('s1', 's2', 's3'));

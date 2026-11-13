-- The Tank P.O. box on an invoice only offers the suppliers we buy tanks from (Carlo, Nov 13, 2026:
-- "which supplier did we buy the tank from: only list suppliers that we buy them from, not all of them").
-- by_item: for each price book item on the invoice, the suppliers that carry it (its supplier part numbers, and its usual supplier).
-- tanks: every supplier we have bought a tank from, or that carries a tank or water heater in the price book.
CREATE OR REPLACE FUNCTION public.tank_suppliers_for(p_invoice bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i invoices;
BEGIN
  SELECT * INTO i FROM invoices WHERE id = p_invoice; IF i.id IS NULL THEN RETURN NULL; END IF;
  IF NOT (public._can_invoice(i.job_id) OR public._tank_office()) THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'by_item', coalesce((SELECT jsonb_object_agg(x.item_id::text, x.sups) FROM (
        SELECT q.item_id, jsonb_agg(DISTINCT q.supplier_id) AS sups FROM (
          SELECT l.item_id, si.supplier_id FROM invoice_lines l JOIN supplier_items si ON si.item_id = l.item_id WHERE l.invoice_id = i.id AND l.item_id IS NOT NULL
          UNION
          SELECT l.item_id, p.preferred_supplier_id FROM invoice_lines l JOIN pricebook_items p ON p.id = l.item_id WHERE l.invoice_id = i.id AND p.preferred_supplier_id IS NOT NULL
        ) q WHERE q.supplier_id IS NOT NULL GROUP BY q.item_id) x), '{}'::jsonb),
    'tanks', coalesce((SELECT jsonb_agg(DISTINCT t.supplier_id) FROM (
        SELECT supplier_id FROM tank_orders WHERE supplier_id IS NOT NULL
        UNION SELECT supplier_id FROM third_party_supplier_payments WHERE supplier_id IS NOT NULL
        UNION SELECT si.supplier_id FROM supplier_items si JOIN pricebook_items p ON p.id = si.item_id
               WHERE p.active IS NOT FALSE AND p.item_type = 'equipment' AND p.name ~* 'water heater|hot water|tankless|\mtank\M'
        UNION SELECT p.preferred_supplier_id FROM pricebook_items p
               WHERE p.active IS NOT FALSE AND p.item_type = 'equipment' AND p.preferred_supplier_id IS NOT NULL AND p.name ~* 'water heater|hot water|tankless|\mtank\M'
      ) t WHERE t.supplier_id IS NOT NULL), '[]'::jsonb));
END $function$;
REVOKE EXECUTE ON FUNCTION public.tank_suppliers_for(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tank_suppliers_for(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

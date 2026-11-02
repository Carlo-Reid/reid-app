-- Vista pairs and the tanks Vista pays suppliers for: show the homeowner (whose address it is), not only the account it's billed to
DO $$ DECLARE s text; BEGIN
  SELECT pg_get_functiondef('public.vista_tank_pairs(bigint, text)'::regprocedure) INTO s;
  IF position('''person''' IN s) = 0 THEN
    s := replace(s, '''street'', l.street,', '''street'', l.street, ''person'', (SELECT display_name FROM customers WHERE id = l.customer_id), ''person_id'', l.customer_id,');
    EXECUTE s;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.partner_supplier_pays(p_partner bigint, p_show text DEFAULT 'open'::text)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN NOT public._can_partner_pay() THEN NULL ELSE coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id, 'invoice_id', i.id, 'invoice_number', i.invoice_number, 'invoice_date', i.invoice_date, 'customer_id', c.id, 'customer_name', c.display_name,
    'person_id', l.customer_id, 'person', (SELECT display_name FROM customers WHERE id = l.customer_id), 'street', l.street, 'city', l.city,
    'labour_id', t.goes_with_invoice_id, 'labour_number', (SELECT invoice_number FROM invoices WHERE id = t.goes_with_invoice_id),
    'supplier', s.name, 'amount', t.amount, 'status', t.status, 'paid_on', t.paid_on, 'reference', t.reference) ORDER BY i.invoice_date DESC, t.id DESC), '[]') END
  FROM third_party_supplier_payments t
  JOIN suppliers s ON s.id = t.supplier_id
  LEFT JOIN invoices i ON i.id = t.invoice_id
  LEFT JOIN customers c ON c.id = i.customer_id
  LEFT JOIN locations l ON l.id = i.location_id
  WHERE t.partner_id = p_partner AND (coalesce(p_show, 'open') = 'all' OR t.status <> 'confirmed_on_statement')
    AND (i.id IS NULL OR i.status <> 'void')
$function$;
NOTIFY pgrst, 'reload schema';

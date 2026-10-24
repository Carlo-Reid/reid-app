-- =====================================================================
-- Improvement 3: contacts.
-- ServiceTitan often has the same phone or email twice on a customer (once on the customer, once on the location),
-- so the app now shows each one once (nothing is deleted: the next sync would only bring them back).
-- This adds the list of customers with no phone or no email, newest customers first, to fix them one by one.
-- Staff who can edit customers. Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.customers_missing_contacts(p_what text DEFAULT 'none', p_years integer DEFAULT 3, p_limit integer DEFAULT 300)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '30s' AS $$
DECLARE v jsonb; lim int := least(greatest(coalesce(p_limit, 300), 1), 1000); since date := current_date - make_interval(years => greatest(coalesce(p_years, 3), 0));
BEGIN
  IF NOT coalesce(public.has_permission('customers.edit'), false) THEN RETURN NULL; END IF;
  WITH k AS (SELECT customer_id, bool_or(kind = 'email' AND value LIKE '%@%') AS em,
                    bool_or(kind IN ('phone', 'mobile') AND length(regexp_replace(value, '\D', '', 'g')) >= 10) AS ph
             FROM customer_contacts GROUP BY customer_id),
  inv AS (SELECT customer_id, max(invoice_date) AS last FROM invoices WHERE status <> 'draft' GROUP BY customer_id),
  c AS (SELECT c.id, c.display_name, c.customer_number, c.do_not_contact, coalesce(k.em, false) AS em, coalesce(k.ph, false) AS ph, inv.last
        FROM customers c LEFT JOIN k ON k.customer_id = c.id LEFT JOIN inv ON inv.customer_id = c.id
        WHERE c.merged_into_id IS NULL AND coalesce(c.status, 'active') <> 'inactive'
          AND (p_years = 0 OR inv.last >= since OR c.created_at >= since)),
  pick AS (SELECT * FROM c WHERE CASE p_what WHEN 'no_email' THEN NOT em WHEN 'no_phone' THEN NOT ph ELSE NOT em AND NOT ph END)
  SELECT jsonb_build_object(
    'counts', (SELECT jsonb_build_object('none', count(*) FILTER (WHERE NOT em AND NOT ph), 'no_email', count(*) FILTER (WHERE NOT em), 'no_phone', count(*) FILTER (WHERE NOT ph), 'all', count(*)) FROM c),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('customer_id', p.id, 'name', p.display_name, 'number', p.customer_number, 'last', p.last,
               'email', p.em, 'phone', p.ph, 'dnc', p.do_not_contact,
               'address', (SELECT concat_ws(', ', l.street, l.city) FROM locations l WHERE l.customer_id = p.id ORDER BY l.active DESC, l.id LIMIT 1))
             ORDER BY p.last DESC NULLS LAST, p.id DESC)
           FROM (SELECT * FROM pick ORDER BY last DESC NULLS LAST, id DESC LIMIT lim) p), '[]'))
  INTO v;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION public.customers_missing_contacts(text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customers_missing_contacts(text, integer, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';

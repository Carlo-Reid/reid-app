-- Marketing: customers who turned marketing off in ServiceTitan (the old system), as a list on the Marketing page:
--   Do not mail (customer), marketing emails off (an email address), texts off (a mobile number).
-- Also: mail campaigns now leave out "Do not mail" customers.
CREATE OR REPLACE FUNCTION public.marketing_st_optouts()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public._can_market() THEN RETURN '[]'::jsonb; END IF;
  RETURN (WITH em AS (SELECT customer_id, string_agg(DISTINCT btrim(value), ', ') AS v FROM customer_contacts
                      WHERE kind = 'email' AND allow_marketing_email = false AND btrim(coalesce(value, '')) <> '' GROUP BY customer_id),
               tx AS (SELECT customer_id, string_agg(DISTINCT btrim(value), ', ') AS v FROM customer_contacts
                      WHERE kind = 'mobile' AND allow_sms = false AND btrim(coalesce(value, '')) <> '' GROUP BY customer_id),
               ids AS (SELECT id AS customer_id FROM customers WHERE marketing_opt_in = false UNION SELECT customer_id FROM em UNION SELECT customer_id FROM tx),
               loc AS (SELECT DISTINCT ON (customer_id) customer_id, street, city FROM locations ORDER BY customer_id, active DESC, id)
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.display_name, 'number', c.customer_number, 'street', loc.street, 'city', loc.city,
             'no_mail', c.marketing_opt_in = false, 'emails_off', em.v, 'texts_off', tx.v, 'active', coalesce(c.status, 'active') <> 'inactive',
             'unsub', c.marketing_unsubscribed_at IS NOT NULL, 'dnc', coalesce(c.do_not_contact, false)) ORDER BY c.display_name), '[]')
    FROM ids JOIN customers c ON c.id = ids.customer_id
    LEFT JOIN em ON em.customer_id = c.id LEFT JOIN tx ON tx.customer_id = c.id LEFT JOIN loc ON loc.customer_id = c.id);
END $$;
GRANT EXECUTE ON FUNCTION public.marketing_st_optouts() TO authenticated;

NOTIFY pgrst, 'reload schema';
SELECT 'ServiceTitan marketing turn-offs list is set up' AS result;

-- Security page, EFT lists (George, Nov 17, 2026): the plans (memberships, from ServiceTitan) of the customers a file matched,
-- so the page can show them beside this page's own PAP mark. The two are kept apart on purpose:
--   customers.pap_list = the PAP mark, set only on the Security page (Mark on a reviewed list, or the buttons on a customer's card)
--   memberships        = the customer's plans, copied from ServiceTitan by the sync
-- This only reads. People with the Security page (owners, or the Security page tick). Safe to run more than once.
CREATE OR REPLACE FUNCTION public.pap_cust_plans(p_ids bigint[])
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._sec_ok(), false) THEN NULL ELSE
    coalesce((SELECT jsonb_object_agg(x.customer_id, x.plans) FROM (
        SELECT m.customer_id,
               jsonb_agg(jsonb_build_object('name', coalesce(pt.name, 'Plan'), 'status', m.status,
                                            'billing', to_jsonb(m) ->> 'billing_frequency',
                                            'since', to_jsonb(m) ->> 'start_date', 'ends', to_jsonb(m) ->> 'end_date')
                         ORDER BY (m.status = 'active') DESC, to_jsonb(m) ->> 'start_date' DESC NULLS LAST, m.id DESC) AS plans
          FROM memberships m LEFT JOIN plan_types pt ON pt.id = m.plan_type_id
         WHERE m.customer_id = ANY (p_ids[1:3000])
         GROUP BY m.customer_id) x), '{}'::jsonb) END
$$;
REVOKE EXECUTE ON FUNCTION public.pap_cust_plans(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_cust_plans(bigint[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

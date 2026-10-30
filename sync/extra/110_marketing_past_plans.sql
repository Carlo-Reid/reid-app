-- Marketing: search past plan members too ("Past plan members"), including plans no longer sold.
-- And the same search for mail (postcards and letters), texting and phone call campaigns (audience.channel):
--   email needs an email address (as before), mail a street address, text a mobile number that allows texts, call any phone number.
CREATE TABLE IF NOT EXISTS public.marketing_touches (   -- mailed / texted / call results for a campaign
  id bigserial PRIMARY KEY, campaign_id bigint NOT NULL, customer_id bigint NOT NULL, channel text NOT NULL, outcome text NOT NULL, note text,
  by_user bigint DEFAULT public.current_app_user_id(), at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS marketing_touches_camp ON public.marketing_touches (campaign_id, customer_id, at DESC);
ALTER TABLE public.marketing_touches ENABLE ROW LEVEL SECURITY;
CREATE OR REPLACE FUNCTION public.marketing_audience(a jsonb, p_limit int DEFAULT 200)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_kind text := coalesce(nullif(a ->> 'kind', ''), 'all');
  v_inst text := nullif(a ->> 'installed', '');       -- yes = we installed for them, no = service only (never an install)
  v_clean text := nullif(a ->> 'cleaning', '');       -- 1..5 = last furnace/AC cleaning over N years ago, never = no cleaning on record
  v_duct text := nullif(a ->> 'duct', '');            -- same for duct cleaning
  v_ckind text := nullif(a ->> 'campaign_kind', '');   -- season / plan / promo: customers who turned that kind off are left out
  v_recent boolean := coalesce((a ->> 'recent_only')::boolean, true);
  v_days int := coalesce(nullif(a ->> 'renew_days', '')::int, 45);
  v_months int := nullif(a ->> 'not_serviced_months', '')::int;
  v_city text := nullif(btrim(a ->> 'city'), '');
  v_eq text := nullif(a ->> 'equipment', '');
  v_age int := nullif(a ->> 'min_age_years', '')::int;
  v_ch text := coalesce(nullif(a ->> 'channel', ''), 'email');
  v_plans bigint[] := ARRAY(SELECT (x)::bigint FROM jsonb_array_elements_text(coalesce(a -> 'plan_types', '[]')) x);
  v jsonb;
BEGIN
  IF NOT public._can_market() THEN RETURN jsonb_build_object('count', 0, 'people', '[]'::jsonb); END IF;
  WITH em AS MATERIALIZED (   -- each customer's email for marketing: the one picked on their file, else their main one that allows marketing
    SELECT DISTINCT ON (cc.customer_id) cc.customer_id, lower(btrim(cc.value)) AS email
    FROM customer_contacts cc JOIN customers c0 ON c0.id = cc.customer_id
    WHERE cc.kind = 'email' AND coalesce(cc.allow_marketing_email, true) AND cc.value ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
      AND (c0.mkt_email IS NULL OR lower(btrim(cc.value)) = lower(btrim(c0.mkt_email)))
    ORDER BY cc.customer_id, cc.is_primary DESC, cc.id),
  ph AS MATERIALIZED (   -- texting: a mobile number that allows texts; calls: any phone, mobile first
    SELECT DISTINCT ON (cc.customer_id) cc.customer_id, btrim(cc.value) AS phone
    FROM customer_contacts cc
    WHERE v_ch IN ('text', 'call') AND btrim(coalesce(cc.value, '')) <> ''
      AND CASE WHEN v_ch = 'text' THEN cc.kind = 'mobile' AND coalesce(cc.allow_sms, true) ELSE cc.kind IN ('mobile', 'phone') END
    ORDER BY cc.customer_id, (cc.kind = 'mobile') DESC, cc.id),
  ad AS MATERIALIZED (   -- mail: the home address (the active one first)
    SELECT DISTINCT ON (customer_id) customer_id, street, unit, city AS acity, province, postal_code
    FROM locations WHERE v_ch = 'mail' AND btrim(coalesce(street, '')) <> ''
    ORDER BY customer_id, active DESC, id),
  recent AS MATERIALIZED (   -- who got a marketing email lately (for "at most one every N days")
    SELECT customer_id, max(sent_at) AS at FROM marketing_sends WHERE status = 'sent' GROUP BY customer_id),
  mem AS MATERIALIZED (
    SELECT DISTINCT ON (m.customer_id) m.customer_id, pt.id AS plan_type_id, pt.name AS plan,
           coalesce(m.end_date, public._mkt_next_anniv(m.start_date)) AS end_date
    FROM memberships m LEFT JOIN plan_types pt ON pt.id = m.plan_type_id
    WHERE m.status = 'active' AND (m.end_date IS NULL OR m.end_date >= current_date)
    ORDER BY m.customer_id, coalesce(m.end_date, public._mkt_next_anniv(m.start_date)) NULLS LAST),
  pastm AS MATERIALIZED (   -- "Past plan members": the newest plan that has ended (expired, cancelled, or past its end date), of the picked plans if any were picked
    SELECT DISTINCT ON (m.customer_id) m.customer_id, pt.name AS plan, coalesce(m.cancelled_on, m.end_date) AS ended
    FROM memberships m LEFT JOIN plan_types pt ON pt.id = m.plan_type_id
    WHERE v_kind = 'past' AND (m.status <> 'active' OR m.end_date < current_date)
      AND (cardinality(v_plans) = 0 OR m.plan_type_id = ANY (v_plans))
    ORDER BY m.customer_id, coalesce(m.cancelled_on, m.end_date) DESC NULLS LAST),
  lj AS MATERIALIZED (SELECT customer_id, max(coalesce(completed_at, created_at)) AS at FROM jobs GROUP BY customer_id),
  jk AS MATERIALIZED (   -- per customer: installs, last cleaning, last duct cleaning (only worked out when those filters are used)
    SELECT j.customer_id,
           bool_or(k = 'install') AS installed,
           max(coalesce(j.completed_at, j.created_at)) FILTER (WHERE k = 'cleaning') AS last_clean,
           max(coalesce(j.completed_at, j.created_at)) FILTER (WHERE k = 'duct') AS last_duct
    FROM jobs j JOIN job_types t ON t.id = j.job_type_id
    CROSS JOIN LATERAL (SELECT public._mkt_job_kind(t.job_class, t.name, j.summary) k) x
    WHERE (v_inst IS NOT NULL OR v_clean IS NOT NULL OR v_duct IS NOT NULL) AND j.status <> 'cancelled' AND k IS NOT NULL
    GROUP BY j.customer_id),
  loc AS MATERIALIZED (SELECT DISTINCT ON (customer_id) customer_id, city FROM locations ORDER BY customer_id, active DESC, id),
  cities AS MATERIALIZED (SELECT DISTINCT customer_id FROM locations WHERE v_city IS NOT NULL AND city ILIKE v_city),
  eq AS MATERIALIZED (   -- the main one of that kind at each home: the newest with a real date (an older one, or ServiceTitan's 1900 "unknown", doesn't count)
    SELECT DISTINCT x.customer_id FROM (
      SELECT DISTINCT ON (e.location_id) l.customer_id, e.install_date
      FROM equipment e JOIN locations l ON l.id = e.location_id
      WHERE v_eq IS NOT NULL AND e.status = 'active'
        AND e.equipment_type_id IN (SELECT t.id FROM equipment_types t WHERE t.name ~* public._mkt_equip_re(v_eq) AND t.name !~* public._mkt_equip_not(v_eq))
      ORDER BY e.location_id, (e.install_date >= DATE '1950-01-01') DESC NULLS LAST, e.install_date DESC NULLS LAST) x
    WHERE v_age IS NULL OR (x.install_date >= DATE '1950-01-01' AND x.install_date <= current_date - make_interval(years => v_age))),
  pick AS MATERIALIZED (
    SELECT c.id, c.display_name, c.customer_type, jk.last_clean, jk.last_duct, em.email, coalesce(mem.plan, CASE WHEN pastm.plan IS NOT NULL THEN pastm.plan || ' (ended' || coalesce(' ' || to_char(pastm.ended, 'Mon YYYY'), '') || ')' END) AS plan, mem.end_date, lj.at AS last_service, c.marketing_token, loc.city,
           ph.phone, ad.street, ad.unit, ad.acity, ad.province, ad.postal_code
    FROM customers c LEFT JOIN em ON em.customer_id = c.id
    LEFT JOIN ph ON ph.customer_id = c.id
    LEFT JOIN ad ON ad.customer_id = c.id
    LEFT JOIN mem ON mem.customer_id = c.id
    LEFT JOIN pastm ON pastm.customer_id = c.id
    LEFT JOIN lj ON lj.customer_id = c.id
    LEFT JOIN loc ON loc.customer_id = c.id
    LEFT JOIN jk ON jk.customer_id = c.id
    WHERE NOT coalesce(c.do_not_contact, false) AND coalesce(c.status, 'active') <> 'inactive'
      AND CASE v_ch WHEN 'email' THEN em.customer_id IS NOT NULL AND c.marketing_unsubscribed_at IS NULL
                    WHEN 'text' THEN ph.customer_id IS NOT NULL AND c.marketing_unsubscribed_at IS NULL
                    WHEN 'call' THEN ph.customer_id IS NOT NULL
                    WHEN 'mail' THEN ad.customer_id IS NOT NULL
                    ELSE false END
      AND (v_ch <> 'call' OR NOT EXISTS (SELECT 1 FROM marketing_touches t WHERE t.customer_id = c.id AND t.outcome = 'dont_call'))   -- "Don't call again"
      AND (v_ch <> 'text' OR NOT EXISTS (SELECT 1 FROM marketing_touches t WHERE t.customer_id = c.id AND t.outcome = 'stop'))       -- replied STOP
      AND CASE v_ckind WHEN 'season' THEN c.mkt_seasonal WHEN 'plan' THEN c.mkt_plans WHEN 'promo' THEN c.mkt_promos ELSE true END
      AND (c.mkt_min_days IS NULL OR NOT EXISTS (SELECT 1 FROM recent r WHERE r.customer_id = c.id AND r.at > now() - make_interval(days => c.mkt_min_days)))
      AND (NOT v_recent OR lj.at > now() - interval '2 years' OR mem.customer_id IS NOT NULL)
      AND CASE v_kind
            WHEN 'members' THEN mem.customer_id IS NOT NULL
            WHEN 'non_members' THEN mem.customer_id IS NULL
            WHEN 'past' THEN pastm.customer_id IS NOT NULL AND mem.customer_id IS NULL   -- had a plan, doesn't have one now
            WHEN 'renewal' THEN mem.end_date BETWEEN current_date AND current_date + v_days
            ELSE true END
      AND (cardinality(v_plans) = 0 OR v_kind = 'past' OR mem.plan_type_id = ANY (v_plans))
      AND (v_inst IS NULL OR (v_inst = 'yes' AND coalesce(jk.installed, false)) OR (v_inst = 'no' AND NOT coalesce(jk.installed, false) AND lj.customer_id IS NOT NULL))
      AND (v_clean IS NULL OR (v_clean = 'never' AND jk.last_clean IS NULL) OR (v_clean ~ '^[0-9]+$' AND jk.last_clean < now() - make_interval(years => v_clean::int)))
      AND (v_duct IS NULL OR (v_duct = 'never' AND jk.last_duct IS NULL) OR (v_duct ~ '^[0-9]+$' AND jk.last_duct < now() - make_interval(years => v_duct::int)))
      AND (v_months IS NULL OR lj.at IS NULL OR lj.at < now() - make_interval(months => v_months))
      AND (v_city IS NULL OR c.id IN (SELECT customer_id FROM cities))
      AND (v_eq IS NULL OR c.id IN (SELECT customer_id FROM eq)))
  SELECT jsonb_build_object(
    'count', (SELECT count(*) FROM pick),
    'people', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', display_name, 'type', customer_type, 'email', email, 'plan', plan, 'plan_end', end_date,
                      'city', city, 'phone', phone, 'street', street, 'unit', unit, 'mail_city', acity, 'province', province, 'postal', postal_code, 'last_service', last_service::date, 'last_clean', last_clean::date, 'last_duct', last_duct::date, 'token', marketing_token) ORDER BY display_name), '[]')
               FROM (SELECT * FROM pick ORDER BY display_name LIMIT least(coalesce(p_limit, 200), 20000)) x))
  INTO v;
  RETURN v;
END $$;



ALTER FUNCTION public.marketing_audience(jsonb, int) SET enable_nestloop = off;

-- every plan, old ones too, with how many have it now and how many used to
CREATE OR REPLACE FUNCTION public.marketing_plan_types_all()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public._can_market() THEN RETURN '[]'::jsonb; END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', pt.id, 'name', pt.name, 'active', coalesce(pt.active, true), 'members', x.now_n, 'past', x.past_n)
            ORDER BY coalesce(pt.active, true) DESC, x.past_n DESC, pt.name), '[]')
    FROM plan_types pt
    CROSS JOIN LATERAL (SELECT
      count(DISTINCT m.customer_id) FILTER (WHERE m.status = 'active' AND (m.end_date IS NULL OR m.end_date >= current_date)) AS now_n,
      count(DISTINCT m.customer_id) FILTER (WHERE m.status <> 'active' OR m.end_date < current_date) AS past_n
      FROM memberships m WHERE m.plan_type_id = pt.id) x
    WHERE x.now_n > 0 OR x.past_n > 0);
END $$;
GRANT EXECUTE ON FUNCTION public.marketing_plan_types_all() TO authenticated;

-- record a mailing, a text or a call result (No answer, Booked, …) for one customer on a campaign
CREATE OR REPLACE FUNCTION public.marketing_touch(p_campaign bigint, p_customer bigint, p_channel text, p_outcome text, p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public._can_market() THEN RAISE EXCEPTION 'You need "Email customers" (Staff page) for marketing.'; END IF;
  IF p_outcome IS NULL OR btrim(p_outcome) = '' THEN RETURN; END IF;
  INSERT INTO marketing_touches (campaign_id, customer_id, channel, outcome, note) VALUES (p_campaign, p_customer, p_channel, p_outcome, nullif(btrim(coalesce(p_note, '')), ''));
END $$;
GRANT EXECUTE ON FUNCTION public.marketing_touch(bigint, bigint, text, text, text) TO authenticated;
-- many at once (Mark all as mailed)
CREATE OR REPLACE FUNCTION public.marketing_touch_many(p_campaign bigint, p_customers bigint[], p_channel text, p_outcome text)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n int;
BEGIN
  IF NOT public._can_market() THEN RAISE EXCEPTION 'You need "Email customers" (Staff page) for marketing.'; END IF;
  INSERT INTO marketing_touches (campaign_id, customer_id, channel, outcome) SELECT p_campaign, x, p_channel, p_outcome FROM unnest(p_customers) x;
  GET DIAGNOSTICS n = ROW_COUNT; RETURN n;
END $$;
GRANT EXECUTE ON FUNCTION public.marketing_touch_many(bigint, bigint[], text, text) TO authenticated;
-- the newest result for each customer on a campaign, and who did it
CREATE OR REPLACE FUNCTION public.marketing_touch_list(p_campaign bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public._can_market() THEN RETURN '[]'::jsonb; END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('customer_id', t.customer_id, 'outcome', t.outcome, 'note', t.note, 'at', t.at, 'tries', t.tries,
            'by', public._emp_name((SELECT u.employee_id FROM app_users u WHERE u.id = t.by_user)))), '[]')
    FROM (SELECT DISTINCT ON (customer_id) customer_id, outcome, note, at, by_user, count(*) OVER (PARTITION BY customer_id) AS tries
          FROM marketing_touches WHERE campaign_id = p_campaign ORDER BY customer_id, at DESC) t);
END $$;
GRANT EXECUTE ON FUNCTION public.marketing_touch_list(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
SELECT 'Marketing can find past plan members, and do mail, texting and phone call campaigns' AS result;

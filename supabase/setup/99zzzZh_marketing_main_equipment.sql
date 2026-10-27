-- 99zzzZh: also runs every night from sync/extra/048_marketing_main_equipment.sql. Safe to run more than once.
-- Marketing: "furnace (or A/C …) at least N years old" looks at the main one at each home: the newest with a real date.
-- An older one that was replaced, or ServiceTitan's 1900 "unknown" date, no longer makes a home look like it has an old furnace.
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
  recent AS MATERIALIZED (   -- who got a marketing email lately (for "at most one every N days")
    SELECT customer_id, max(sent_at) AS at FROM marketing_sends WHERE status = 'sent' GROUP BY customer_id),
  mem AS MATERIALIZED (
    SELECT DISTINCT ON (m.customer_id) m.customer_id, pt.id AS plan_type_id, pt.name AS plan,
           coalesce(m.end_date, public._mkt_next_anniv(m.start_date)) AS end_date
    FROM memberships m LEFT JOIN plan_types pt ON pt.id = m.plan_type_id
    WHERE m.status = 'active' AND (m.end_date IS NULL OR m.end_date >= current_date)
    ORDER BY m.customer_id, coalesce(m.end_date, public._mkt_next_anniv(m.start_date)) NULLS LAST),
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
    SELECT c.id, c.display_name, c.customer_type, jk.last_clean, jk.last_duct, em.email, mem.plan, mem.end_date, lj.at AS last_service, c.marketing_token, loc.city
    FROM customers c JOIN em ON em.customer_id = c.id
    LEFT JOIN mem ON mem.customer_id = c.id
    LEFT JOIN lj ON lj.customer_id = c.id
    LEFT JOIN loc ON loc.customer_id = c.id
    LEFT JOIN jk ON jk.customer_id = c.id
    WHERE NOT coalesce(c.do_not_contact, false) AND c.marketing_unsubscribed_at IS NULL AND coalesce(c.status, 'active') <> 'inactive'
      AND CASE v_ckind WHEN 'season' THEN c.mkt_seasonal WHEN 'plan' THEN c.mkt_plans WHEN 'promo' THEN c.mkt_promos ELSE true END
      AND (c.mkt_min_days IS NULL OR NOT EXISTS (SELECT 1 FROM recent r WHERE r.customer_id = c.id AND r.at > now() - make_interval(days => c.mkt_min_days)))
      AND (NOT v_recent OR lj.at > now() - interval '2 years' OR mem.customer_id IS NOT NULL)
      AND CASE v_kind
            WHEN 'members' THEN mem.customer_id IS NOT NULL
            WHEN 'non_members' THEN mem.customer_id IS NULL
            WHEN 'renewal' THEN mem.end_date BETWEEN current_date AND current_date + v_days
            ELSE true END
      AND (cardinality(v_plans) = 0 OR mem.plan_type_id = ANY (v_plans))
      AND (v_inst IS NULL OR (v_inst = 'yes' AND coalesce(jk.installed, false)) OR (v_inst = 'no' AND NOT coalesce(jk.installed, false) AND lj.customer_id IS NOT NULL))
      AND (v_clean IS NULL OR (v_clean = 'never' AND jk.last_clean IS NULL) OR (v_clean ~ '^[0-9]+$' AND jk.last_clean < now() - make_interval(years => v_clean::int)))
      AND (v_duct IS NULL OR (v_duct = 'never' AND jk.last_duct IS NULL) OR (v_duct ~ '^[0-9]+$' AND jk.last_duct < now() - make_interval(years => v_duct::int)))
      AND (v_months IS NULL OR lj.at IS NULL OR lj.at < now() - make_interval(months => v_months))
      AND (v_city IS NULL OR c.id IN (SELECT customer_id FROM cities))
      AND (v_eq IS NULL OR c.id IN (SELECT customer_id FROM eq)))
  SELECT jsonb_build_object(
    'count', (SELECT count(*) FROM pick),
    'people', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', display_name, 'type', customer_type, 'email', email, 'plan', plan, 'plan_end', end_date,
                      'city', city, 'last_service', last_service::date, 'last_clean', last_clean::date, 'last_duct', last_duct::date, 'token', marketing_token) ORDER BY display_name), '[]')
               FROM (SELECT * FROM pick ORDER BY display_name LIMIT least(coalesce(p_limit, 200), 20000)) x))
  INTO v;
  RETURN v;
END $$;



-- counting is much faster this way on a big customer list
ALTER FUNCTION public.marketing_audience(jsonb, int) SET enable_nestloop = off;

NOTIFY pgrst, 'reload schema';
SELECT 'More marketing filters are set up' AS result;

ALTER FUNCTION public.marketing_audience(jsonb, int) SET enable_nestloop = off;
NOTIFY pgrst, 'reload schema';

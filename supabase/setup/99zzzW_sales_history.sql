-- Sales: installs made in ServiceTitan without a link now show on their sale; Carlo view (sales by year, month, day)
CREATE OR REPLACE FUNCTION public.sales_list(p_seller bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH me AS (SELECT public._my_employee() AS emp, public.current_app_user_id() AS uid, public._sales_boss() AS boss),
  who AS (   -- whose jobs: one sales person (p_seller), or everyone (owners/dispatchers with no p_seller)
    SELECT CASE WHEN p_seller IS NULL AND me.boss THEN NULL ELSE coalesce(p_seller, me.uid) END AS seller FROM me),
  ok AS (SELECT (me.boss OR who.seller = me.uid OR EXISTS (SELECT 1 FROM sales_viewers v WHERE v.viewer_user_id = me.uid AND v.seller_user_id = who.seller)) AS ok FROM me, who),
  tgt AS (SELECT u.id AS uid, u.employee_id AS emp FROM app_users u, who WHERE u.id = who.seller),
  sp AS (SELECT id AS uid, employee_id AS emp FROM app_users WHERE role = 'sales'),          -- the sales people
  csj AS (SELECT * FROM public._comm_sale_jobs()),   -- sold and done on the same call (e.g. a humidifier on a maintenance visit)
  j AS (
    SELECT jb.* FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id, me
    WHERE t.job_class = 'sales' AND public._is_install_sale(t.name) AND jb.created_at > now() - interval '18 months'
      AND (SELECT ok FROM ok)
      AND NOT EXISTS (SELECT 1 FROM estimates ec WHERE ec.job_id = jb.id AND ec.cancelled_at IS NOT NULL)
      AND jb.sales_cancelled_at IS NULL   -- cancelled from the Sales page   -- cancelled estimates leave the Sales page
      AND CASE WHEN (SELECT seller FROM who) IS NULL
               -- everyone: jobs of the sales people, and sales jobs booked in this app by the office (not old ServiceTitan ones)
               THEN jb.sales_user_id IS NOT NULL
                    OR EXISTS (SELECT 1 FROM sp WHERE sp.uid = jb.booked_by_user_id OR sp.emp = jb.sold_by_employee_id
                              OR sp.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))
                    OR EXISTS (SELECT 1 FROM app_users u WHERE u.id = jb.booked_by_user_id AND u.role <> 'technician')
                    OR EXISTS (SELECT 1 FROM estimates es JOIN sp ON sp.emp = es.sold_by_employee_id WHERE es.job_id = jb.id)   -- the proposal was sold by a sales person
                    OR EXISTS (SELECT 1 FROM estimates es JOIN jobs ij ON (ij.sold_estimate_id = es.id OR ij.from_estimate_id = es.id) AND ij.id <> jb.id
                               WHERE es.job_id = jb.id AND es.status = 'accepted')   -- it was sold and became an install, whoever is on it
               ELSE EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = jb.sales_user_id OR (jb.sales_user_id IS NULL AND (tgt.uid = jb.booked_by_user_id OR tgt.emp = jb.sold_by_employee_id))
                              OR (jb.sales_user_id IS NULL AND tgt.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))
                              OR (jb.sales_user_id IS NULL AND tgt.emp IN (SELECT es.sold_by_employee_id FROM estimates es WHERE es.job_id = jb.id))
                              OR (jb.sales_user_id IS NULL AND tgt.emp IN (SELECT it.salesperson_id FROM estimates es JOIN jobs ij ON (ij.sold_estimate_id = es.id OR ij.from_estimate_id = es.id)
                                                                           JOIN install_tracking it ON it.job_id = ij.id WHERE es.job_id = jb.id AND es.status = 'accepted'))) END
    ORDER BY jb.created_at DESC LIMIT 1500),
  rows AS (
    SELECT jsonb_build_object(
      'job_id', j.id, 'job_number', j.job_number, 'status', j.status, 'summary', j.summary, 'type', t.name, 'kind', j.sales_kind, 'on_site', j.sales_on_site_at,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = j.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', (SELECT public._emp_name(va.employee_id) FROM visit_assignments va WHERE va.visit_id = v.id ORDER BY va.role = 'lead' DESC LIMIT 1),
      'sales_person', coalesce((SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = coalesce(j.sales_user_id, CASE WHEN EXISTS (SELECT 1 FROM app_users b WHERE b.id = j.booked_by_user_id AND b.role = 'sales') THEN j.booked_by_user_id END)),
                               (SELECT public._emp_name(it.salesperson_id) FROM jobs ij JOIN install_tracking it ON it.job_id = ij.id
                                 WHERE (ij.sold_estimate_id = e.id OR ij.from_estimate_id = e.id) AND it.salesperson_id IS NOT NULL LIMIT 1),
                               public._emp_name(e.sold_by_employee_id)),
      'est_id', e.id, 'est_number', e.estimate_number, 'est_status', e.status, 'est_total', (SELECT max(t2.tot) FROM (SELECT sum(el.line_total) tot FROM estimate_options o JOIN estimate_lines el ON el.estimate_option_id = o.id WHERE o.estimate_id = e.id GROUP BY o.id) t2),
      'sold_total', (SELECT sum(el.line_total) FROM estimate_lines el WHERE el.estimate_option_id = e.accepted_option_id),
      'stage', CASE WHEN e.status = 'accepted' THEN 'closed' WHEN e.status IN ('lost', 'declined', 'expired') OR j.status = 'cancelled' THEN 'lost'
                    WHEN e.id IS NOT NULL THEN 'estimate' ELSE 'booked' END,
      'sort', coalesce(e.updated_at, j.created_at)) AS x, e.id AS est, j.id AS jid
    FROM j JOIN job_types t ON t.id = j.job_type_id JOIN customers c ON c.id = j.customer_id LEFT JOIN locations l ON l.id = j.location_id
    LEFT JOIN LATERAL (SELECT * FROM visits v WHERE v.job_id = j.id ORDER BY v.visit_number DESC LIMIT 1) v ON true
    LEFT JOIN LATERAL (SELECT * FROM estimates e WHERE e.job_id = j.id ORDER BY e.id DESC LIMIT 1) e ON true),
  -- proposals sold on any other kind of call (service, maintenance…) that turned into an install
  o AS (
    SELECT e.id AS est, sj.id AS jid FROM estimates e JOIN jobs sj ON sj.id = e.job_id JOIN job_types st ON st.id = sj.job_type_id
    WHERE e.status = 'accepted' AND e.cancelled_at IS NULL AND e.created_at > now() - interval '18 months' AND (SELECT ok FROM ok)
      AND NOT (st.job_class = 'sales' AND public._is_install_sale(st.name))      -- sales jobs are above
      AND sj.sales_cancelled_at IS NULL
      AND (EXISTS (SELECT 1 FROM jobs ij JOIN job_types it ON it.id = ij.job_type_id WHERE ij.id <> sj.id AND it.job_class = 'install' AND (ij.sold_estimate_id = e.id OR ij.from_estimate_id = e.id))
           OR EXISTS (SELECT 1 FROM csj WHERE csj.sale_job_id = sj.id AND csj.est_id = e.id))
      AND CASE WHEN (SELECT seller FROM who) IS NULL THEN true
               ELSE EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = sj.sales_user_id OR (sj.sales_user_id IS NULL AND tgt.emp = e.sold_by_employee_id)) END
    ORDER BY e.created_at DESC LIMIT 2000),
  orows AS (
    SELECT jsonb_build_object(
      'job_id', sj.id, 'job_number', sj.job_number, 'status', sj.status, 'summary', sj.summary, 'type', t.name, 'kind', NULL, 'from_call', true,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = sj.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', (SELECT public._emp_name(va.employee_id) FROM visit_assignments va WHERE va.visit_id = v.id ORDER BY va.role = 'lead' DESC LIMIT 1),
      'sales_person', coalesce((SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = sj.sales_user_id), public._emp_name(e.sold_by_employee_id)),
      'est_id', e.id, 'est_number', e.estimate_number, 'est_status', e.status,
      'est_total', (SELECT max(t2.tot) FROM (SELECT sum(el.line_total) tot FROM estimate_options op JOIN estimate_lines el ON el.estimate_option_id = op.id WHERE op.estimate_id = e.id GROUP BY op.id) t2),
      'sold_total', (SELECT sum(el.line_total) FROM estimate_lines el WHERE el.estimate_option_id = e.accepted_option_id),
      'stage', 'closed', 'sort', coalesce(e.updated_at, sj.created_at)) AS x, e.id AS est, sj.id AS jid
    FROM o JOIN estimates e ON e.id = o.est JOIN jobs sj ON sj.id = o.jid JOIN job_types t ON t.id = sj.job_type_id JOIN customers c ON c.id = sj.customer_id
    LEFT JOIN locations l ON l.id = sj.location_id
    LEFT JOIN LATERAL (SELECT * FROM visits v WHERE v.job_id = sj.id ORDER BY v.visit_number DESC LIMIT 1) v ON true),
  deals AS (SELECT x, est, jid FROM rows UNION ALL SELECT x, est, jid FROM orows),
  -- every proposal on each deal's sales call (the sold one, or another one on the same call)
  dl AS (SELECT r.est, r.jid, es.id AS e2 FROM deals r JOIN estimates es ON es.job_id = r.jid WHERE r.est IS NOT NULL
         UNION SELECT r.est, r.jid, r.est FROM deals r WHERE r.est IS NOT NULL),
  -- install jobs linked to any of them
  lk AS (SELECT dl.est, dl.jid, ij.id AS ij FROM dl JOIN jobs ij ON ij.sold_estimate_id = dl.e2 WHERE ij.id <> dl.jid
         UNION SELECT dl.est, dl.jid, ij.id FROM dl JOIN jobs ij ON ij.from_estimate_id = dl.e2 WHERE ij.id <> dl.jid),
  -- the Install jobs those deals turned into (made in the app, or linked in ServiceTitan)
  inst AS (
    SELECT DISTINCT ON (ij.id) jsonb_build_object(
      'job_id', ij.id, 'job_number', ij.job_number, 'status', ij.status, 'summary', ij.summary, 'type', t.name,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = ij.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', public._emp_name(coalesce(ij.sold_by_employee_id, e.sold_by_employee_id)),
      'est_id', e.id, 'est_number', e.estimate_number, 'est_status', e.status,
      'sold_total', (SELECT sum(el.line_total) FROM estimate_lines el WHERE el.estimate_option_id = e.accepted_option_id),
      'stage', 'install', 'sort', ij.created_at) AS x, r.est
    FROM lk JOIN deals r ON r.est = lk.est AND r.jid = lk.jid JOIN jobs ij ON ij.id = lk.ij JOIN estimates e ON e.id = r.est
    JOIN job_types t ON t.id = ij.job_type_id JOIN customers c ON c.id = ij.customer_id LEFT JOIN locations l ON l.id = ij.location_id
    LEFT JOIN LATERAL (SELECT * FROM visits v WHERE v.job_id = ij.id ORDER BY v.visit_number DESC LIMIT 1) v ON true
    WHERE r.est IS NOT NULL AND t.job_class = 'install'   -- only real install jobs (not a follow-up service call)
    ORDER BY ij.id),
  -- a sold deal with no linked install: the customer's install job made in ServiceTitan without a link
  -- (made from a week before to 6 months after the sale, not tied to any proposal), the first one
  inst2 AS (
    SELECT DISTINCT ON (r.est) jsonb_build_object(
      'job_id', ij.id, 'job_number', ij.job_number, 'status', ij.status, 'summary', ij.summary, 'type', t.name,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = ij.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', public._emp_name(coalesce(ij.sold_by_employee_id, e.sold_by_employee_id)),
      'est_id', e.id, 'est_number', e.estimate_number, 'est_status', e.status,
      'sold_total', (SELECT sum(el.line_total) FROM estimate_lines el WHERE el.estimate_option_id = e.accepted_option_id),
      'stage', 'install', 'guessed', true, 'sort', ij.created_at) AS x
    FROM deals r JOIN estimates e ON e.id = r.est AND e.status = 'accepted'
    JOIN jobs ij ON ij.customer_id = e.customer_id AND ij.id <> r.jid AND ij.sold_estimate_id IS NULL AND ij.from_estimate_id IS NULL
         AND ij.created_at BETWEEN coalesce(e.accepted_at, e.created_at) - interval '7 days' AND coalesce(e.accepted_at, e.created_at) + interval '6 months'
    JOIN job_types t ON t.id = ij.job_type_id AND t.job_class = 'install'
    JOIN customers c ON c.id = ij.customer_id LEFT JOIN locations l ON l.id = ij.location_id
    LEFT JOIN LATERAL (SELECT * FROM visits v WHERE v.job_id = ij.id ORDER BY v.visit_number DESC LIMIT 1) v ON true
    WHERE r.est IS NOT NULL AND (r.x->>'stage') = 'closed'
      AND r.est NOT IN (SELECT inst.est FROM inst)
      AND NOT EXISTS (SELECT 1 FROM csj WHERE csj.sale_job_id = r.jid AND csj.est_id = r.est)
    ORDER BY r.est, ij.created_at),
  here AS (
    SELECT jsonb_build_object(
      'job_id', j2.id, 'job_number', j2.job_number, 'status', j2.status, 'summary', j2.summary, 'type', t.name, 'same_call', true,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = j2.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', public._emp_name(e.sold_by_employee_id),
      'est_id', e.id, 'est_number', e.estimate_number, 'est_status', e.status,
      'sold_total', (SELECT sum(el.line_total) FROM estimate_lines el WHERE el.estimate_option_id = e.accepted_option_id),
      'stage', 'install', 'sort', j2.created_at) AS x
    FROM deals r JOIN csj ON csj.sale_job_id = r.jid AND csj.est_id = r.est JOIN jobs j2 ON j2.id = csj.job_id JOIN estimates e ON e.id = r.est
    JOIN job_types t ON t.id = j2.job_type_id JOIN customers c ON c.id = j2.customer_id LEFT JOIN locations l ON l.id = j2.location_id
    LEFT JOIN LATERAL (SELECT * FROM visits v WHERE v.job_id = j2.id ORDER BY v.visit_number DESC LIMIT 1) v ON true)
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb
              ELSE coalesce((SELECT jsonb_agg(x ORDER BY x->>'sort' DESC) FROM (SELECT x FROM deals UNION ALL SELECT x FROM inst UNION ALL SELECT x FROM inst2 UNION ALL SELECT x FROM here) a), '[]'::jsonb) END
$function$;

REVOKE EXECUTE ON FUNCTION public.sales_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_list(bigint) TO authenticated;

-- Carlo view on the Sales page: every sale made (every sold proposal), by year, month and day.
-- A sale = a proposal marked sold (accepted), not cancelled, worth more than $0.
-- Sold day = the day it was sold (or, for old ServiceTitan ones with no sold time, the day the job was made), Ottawa time.
-- Whose: everyone (owners / sales bosses), or one sales person (the "Sales page of" picker), with the same rules as the Sales page.
DROP FUNCTION IF EXISTS public._sales_hist_rows(bigint) CASCADE;   -- (its columns grew: partner)
CREATE OR REPLACE FUNCTION public._sales_hist_rows(p_seller bigint DEFAULT NULL)
 RETURNS TABLE(est_id bigint, est_number text, job_id bigint, job_number text, job_type text, sold_on date, amount numeric,
               customer_id bigint, customer text, address text, sales_person text, partner text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH me AS (SELECT public.current_app_user_id() AS uid, public._sales_boss() AS boss),
  who AS (SELECT CASE WHEN p_seller IS NULL AND me.boss THEN NULL ELSE coalesce(p_seller, me.uid) END AS seller FROM me),
  ok AS (SELECT public.current_staff_role() IS NOT NULL
                AND (me.boss OR who.seller = me.uid OR EXISTS (SELECT 1 FROM sales_viewers v WHERE v.viewer_user_id = me.uid AND v.seller_user_id = who.seller)) AS ok FROM me, who),
  tgt AS (SELECT u.id AS uid, u.employee_id AS emp FROM app_users u, who WHERE u.id = who.seller),
  -- each partner by the first word of its name (once, not for every sale)
  pw AS MATERIALIZED (SELECT DISTINCT ON (lower(split_part(btrim(name), ' ', 1))) lower(split_part(btrim(name), ' ', 1)) AS w, btrim(name) AS name
                      FROM partners ORDER BY lower(split_part(btrim(name), ' ', 1)), id),
  s AS (
    SELECT e.id AS est_id, e.estimate_number AS est_number, j.id AS job_id, j.job_number, t.name AS job_type,
           (coalesce(e.accepted_at, j.created_at, e.created_at) AT TIME ZONE 'America/Toronto')::date AS sold_on,
           coalesce((SELECT sum(el.line_total) FROM estimate_lines el WHERE el.estimate_option_id = e.accepted_option_id), 0) AS amount,
           c.id AS customer_id, c.display_name AS customer, concat_ws(', ', l.street, l.city) AS address,
           coalesce((SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = j.sales_user_id),
                    public._emp_name(e.sold_by_employee_id)) AS sales_person,
           -- who it's for: the job's partner, or the partner the job type is named after ("Rona - Lead"), else Reid
           coalesce(btrim(pj.name), pt.name, 'Reid') AS partner
    FROM estimates e JOIN jobs j ON j.id = e.job_id LEFT JOIN job_types t ON t.id = j.job_type_id
    LEFT JOIN partners pj ON pj.id = j.partner_id
    LEFT JOIN pw pt ON pt.w = lower(split_part(btrim(t.name), ' ', 1)) AND length(split_part(btrim(t.name), ' ', 1)) > 2
    LEFT JOIN customers c ON c.id = coalesce(e.customer_id, j.customer_id)
    LEFT JOIN locations l ON l.id = coalesce(e.location_id, j.location_id)
    WHERE e.status = 'accepted' AND e.cancelled_at IS NULL AND j.sales_cancelled_at IS NULL AND (SELECT ok FROM ok)
      AND ((SELECT seller FROM who) IS NULL
           OR EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = j.sales_user_id OR (j.sales_user_id IS NULL AND tgt.emp = e.sold_by_employee_id))))
  SELECT * FROM s WHERE s.amount > 0
$function$;
REVOKE EXECUTE ON FUNCTION public._sales_hist_rows(bigint) FROM PUBLIC, anon, authenticated;

-- Totals for every day and sales person that had a sale: [{d, sp, n, amt}]. The page adds them up into months, years and people.
CREATE OR REPLACE FUNCTION public.sales_history_days(p_seller bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  SELECT coalesce(jsonb_agg(jsonb_build_object('d', d, 'sp', sp, 'pt', pt, 'n', n, 'amt', amt) ORDER BY d), '[]'::jsonb)
  FROM (SELECT sold_on AS d, coalesce(sales_person, '') AS sp, partner AS pt, count(*) AS n, sum(amount) AS amt FROM public._sales_hist_rows(p_seller) GROUP BY 1, 2, 3) x
$function$;
REVOKE EXECUTE ON FUNCTION public.sales_history_days(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_history_days(bigint) TO authenticated;

-- The sales themselves for a day, month or year (from - to, both included)
CREATE OR REPLACE FUNCTION public.sales_history(p_seller bigint DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.sold_on DESC, r.amount DESC), '[]'::jsonb)
  FROM public._sales_hist_rows(p_seller) r
  WHERE (p_from IS NULL OR r.sold_on >= p_from) AND (p_to IS NULL OR r.sold_on <= p_to)
$function$;
REVOKE EXECUTE ON FUNCTION public.sales_history(bigint, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_history(bigint, date, date) TO authenticated;
NOTIFY pgrst, 'reload schema';

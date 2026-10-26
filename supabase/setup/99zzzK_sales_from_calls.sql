-- 99zzzK: Sales page also shows proposals sold on service calls (and other calls) that became an install,
-- and installs linked the ServiceTitan way. Safe to run more than once.
CREATE INDEX IF NOT EXISTS jobs_sold_estimate_idx ON public.jobs (sold_estimate_id) WHERE sold_estimate_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS jobs_from_estimate_idx ON public.jobs (from_estimate_id) WHERE from_estimate_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS estimates_accepted_idx ON public.estimates (created_at) WHERE status = 'accepted';
-- Sales page: also the proposals sold on other calls (a service call, a maintenance visit…) that became an install,
-- and installs linked the ServiceTitan way (the install job's sold estimate) as well as the app's way.
CREATE OR REPLACE FUNCTION public.sales_list(p_seller bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH me AS (SELECT public._my_employee() AS emp, public.current_app_user_id() AS uid, public._sales_boss() AS boss),
  who AS (   -- whose jobs: one sales person (p_seller), or everyone (owners/dispatchers with no p_seller)
    SELECT CASE WHEN p_seller IS NULL AND me.boss THEN NULL ELSE coalesce(p_seller, me.uid) END AS seller FROM me),
  ok AS (SELECT (me.boss OR who.seller = me.uid OR EXISTS (SELECT 1 FROM sales_viewers v WHERE v.viewer_user_id = me.uid AND v.seller_user_id = who.seller)) AS ok FROM me, who),
  tgt AS (SELECT u.id AS uid, u.employee_id AS emp FROM app_users u, who WHERE u.id = who.seller),
  sp AS (SELECT id AS uid, employee_id AS emp FROM app_users WHERE role = 'sales'),          -- the sales people
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
               ELSE EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = jb.sales_user_id OR (jb.sales_user_id IS NULL AND (tgt.uid = jb.booked_by_user_id OR tgt.emp = jb.sold_by_employee_id))
                              OR (jb.sales_user_id IS NULL AND tgt.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))) END
    ORDER BY jb.created_at DESC LIMIT 400),
  rows AS (
    SELECT jsonb_build_object(
      'job_id', j.id, 'job_number', j.job_number, 'status', j.status, 'summary', j.summary, 'type', t.name, 'kind', j.sales_kind, 'on_site', j.sales_on_site_at,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = j.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', (SELECT public._emp_name(va.employee_id) FROM visit_assignments va WHERE va.visit_id = v.id ORDER BY va.role = 'lead' DESC LIMIT 1),
      'sales_person', (SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = coalesce(j.sales_user_id, CASE WHEN EXISTS (SELECT 1 FROM app_users b WHERE b.id = j.booked_by_user_id AND b.role = 'sales') THEN j.booked_by_user_id END)),
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
      AND EXISTS (SELECT 1 FROM jobs ij WHERE ij.id <> sj.id AND (ij.sold_estimate_id = e.id OR ij.from_estimate_id = e.id))
      AND CASE WHEN (SELECT seller FROM who) IS NULL THEN true
               ELSE EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = sj.sales_user_id OR (sj.sales_user_id IS NULL AND tgt.emp = e.sold_by_employee_id)) END
    ORDER BY e.created_at DESC LIMIT 300),
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
      'stage', 'install', 'sort', ij.created_at) AS x
    FROM deals r JOIN jobs ij ON (ij.from_estimate_id = r.est OR ij.sold_estimate_id = r.est) AND ij.id <> r.jid JOIN estimates e ON e.id = r.est
    JOIN job_types t ON t.id = ij.job_type_id JOIN customers c ON c.id = ij.customer_id LEFT JOIN locations l ON l.id = ij.location_id
    LEFT JOIN LATERAL (SELECT * FROM visits v WHERE v.job_id = ij.id ORDER BY v.visit_number DESC LIMIT 1) v ON true
    WHERE r.est IS NOT NULL
    ORDER BY ij.id)
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb
              ELSE coalesce((SELECT jsonb_agg(x ORDER BY x->>'sort' DESC) FROM (SELECT x FROM deals UNION ALL SELECT x FROM inst) a), '[]'::jsonb) END
$function$;

REVOKE EXECUTE ON FUNCTION public.sales_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_list(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

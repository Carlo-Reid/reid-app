-- =====================================================================
-- Sales made on a call (service, maintenance…) and done on that same call count like an install:
-- a proposal sold by someone who earns commission, with work from the commission list (Humidifier, Furnace, HRV…),
-- when no separate install job was made for it. They show on the Sales, Installs and Commissions pages,
-- and the sale / commission is the sold proposal (not the visit charges on the same invoice). Safe to run more than once.
-- =====================================================================
DROP FUNCTION IF EXISTS public._comm_sale_jobs();
CREATE OR REPLACE FUNCTION public._comm_sale_jobs()
RETURNS TABLE (job_id bigint, est_id bigint, sale_job_id bigint) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public SET jit = off AS $f$
  WITH earners AS (SELECT employee_id FROM commission_rates UNION SELECT employee_id FROM commission_group_rates),
  sold AS (
    SELECT e.id, e.job_id, e.accepted_option_id FROM estimates e JOIN jobs j ON j.id = e.job_id JOIN job_types t ON t.id = j.job_type_id
    WHERE e.status = 'accepted' AND e.cancelled_at IS NULL AND e.created_at > now() - interval '3 years'
      AND t.job_class NOT IN ('install', 'sales') AND j.status <> 'cancelled'
      AND e.sold_by_employee_id IN (SELECT employee_id FROM earners)
      AND NOT EXISTS (SELECT 1 FROM jobs ij JOIN job_types it ON it.id = ij.job_type_id
                      WHERE ij.id <> e.job_id AND it.job_class = 'install' AND (ij.sold_estimate_id = e.id OR ij.from_estimate_id = e.id))),
  items AS (SELECT DISTINCT x.item_id FROM sold s JOIN estimate_lines x ON x.estimate_option_id = s.accepted_option_id WHERE x.item_id IS NOT NULL),
  counts AS (SELECT i.item_id FROM items i JOIN commission_groups g ON g.id = public._comm_group(i.item_id) WHERE g.name <> 'Other')
  SELECT DISTINCT ON (w.work_job) w.work_job, s.id, s.job_id FROM sold s
  CROSS JOIN LATERAL (SELECT coalesce((SELECT lj.id FROM jobs lj JOIN job_types lt ON lt.id = lj.job_type_id
                                       WHERE lj.id <> s.job_id AND lt.job_class <> 'sales' AND lj.status <> 'cancelled'
                                         AND (lj.sold_estimate_id = s.id OR lj.from_estimate_id = s.id)
                                       ORDER BY lj.created_at DESC LIMIT 1), s.job_id) AS work_job) w
  WHERE EXISTS (SELECT 1 FROM estimate_lines x JOIN counts c ON c.item_id = x.item_id WHERE x.estimate_option_id = s.accepted_option_id)
  ORDER BY w.work_job, s.id DESC
$f$;
REVOKE EXECUTE ON FUNCTION public._comm_sale_jobs() FROM PUBLIC, anon, authenticated;

-- what a proposal was sold for (the sold option, before tax)
CREATE OR REPLACE FUNCTION public._est_sold_total(p_est bigint)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT round(sum(x.line_total), 2) FROM estimates e JOIN estimate_lines x ON x.estimate_option_id = e.accepted_option_id
  WHERE e.id = p_est AND x.parent_line_id IS NULL
$f$;
-- the commission on a sold proposal: each line × that line's % for this person
CREATE OR REPLACE FUNCTION public._comm_est(p_emp bigint, p_est bigint)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT CASE WHEN p_emp IS NULL OR p_est IS NULL THEN NULL ELSE
    round(sum(x.line_total * coalesce(CASE WHEN x.item_id IS NULL THEN (SELECT pct FROM commission_rates WHERE employee_id = p_emp) ELSE public._comm_pct(p_emp, x.item_id) END, 0) / 100), 2) END
  FROM estimates e JOIN estimate_lines x ON x.estimate_option_id = e.accepted_option_id
  WHERE e.id = p_est AND x.parent_line_id IS NULL
$f$;
REVOKE EXECUTE ON FUNCTION public._est_sold_total(bigint), public._comm_est(bigint, bigint) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.install_list(p_from date, p_to date)
 RETURNS TABLE(job_id bigint, job_number text, job_type text, completed_on date, customer_id bigint, customer_name text, address text, salesperson_id bigint, salesperson text, sale_amount numeric, invoiced numeric, owing numeric, commission_pct numeric, commission_amount numeric, customer_paid boolean, prepaid_at timestamp with time zone, prepaid_amount numeric, paid_at timestamp with time zone, paid_amount numeric, rebate_status text, rebate_amount numeric, rebate_program text, financing_status text, financing_company text, financing_amount numeric, registered_at date, registration_number text, equipment jsonb, notes text, tracked boolean, job_status text, sold_on date, date_on date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH cs AS (SELECT * FROM public._comm_sale_jobs()),
  d AS (   -- each install job's day: when it was done, or (not done yet) its booked day, else the day it was sold
    SELECT j.id, CASE WHEN j.status IN ('completed', 'invoiced', 'closed')
                      THEN coalesce(j.completed_at::date, (SELECT max(v.completed_at) FROM visits v WHERE v.job_id = j.id)::date,
                                    coalesce((SELECT e.accepted_at FROM estimates e WHERE e.id = j.sold_estimate_id), j.created_at)::date)
                      ELSE coalesce((SELECT min(v.scheduled_date) FROM visits v WHERE v.job_id = j.id AND v.status <> 'cancelled'),
                                    coalesce((SELECT e.accepted_at FROM estimates e WHERE e.id = j.sold_estimate_id), j.created_at)::date) END AS day
    FROM jobs j JOIN job_types t ON t.id = j.job_type_id
    WHERE public._can_installs() AND j.status <> 'cancelled'
      AND (t.job_class = 'install' OR j.id IN (SELECT cs.job_id FROM cs))),   -- or work sold and done on the same call
  pick AS (SELECT d.id, d.day FROM d WHERE (p_from IS NULL OR d.day >= p_from) AND (p_to IS NULL OR d.day <= p_to) ORDER BY d.day DESC, d.id DESC LIMIT 3000),
  base AS (
    SELECT j.*, t.name AS type_name, coalesce(j.completed_at, (SELECT max(v.completed_at) FROM visits v WHERE v.job_id = j.id))::date AS done_on,
           it.*, it.job_id AS it_job,
           coalesce(it.salesperson_id, (SELECT e.sold_by_employee_id FROM estimates e WHERE e.id = j.sold_estimate_id), j.sold_by_employee_id,
                    (SELECT e.sold_by_employee_id FROM cs JOIN estimates e ON e.id = cs.est_id WHERE cs.job_id = j.id LIMIT 1),
                    (SELECT e.sold_by_employee_id FROM estimates e WHERE e.job_id = j.id AND e.status = 'accepted' ORDER BY e.accepted_at DESC NULLS LAST LIMIT 1)) AS sp,
           (SELECT coalesce(sum(i.subtotal), 0) FROM invoices i WHERE i.job_id = j.id AND i.status NOT IN ('void', 'draft')) AS inv_sub,
           (SELECT coalesce(sum(i.balance_due) FILTER (WHERE i.not_owed_reason IS NULL), 0) FROM invoices i WHERE i.job_id = j.id AND i.status NOT IN ('void', 'draft')) AS inv_owing,
           (SELECT count(*) FROM invoices i WHERE i.job_id = j.id AND i.status NOT IN ('void', 'draft')) AS inv_n, pk.day AS pick_day,
           coalesce((SELECT e.accepted_at FROM estimates e WHERE e.id = j.sold_estimate_id), j.created_at)::date AS sold_day,
           (SELECT min(v.scheduled_date) FROM visits v WHERE v.job_id = j.id AND v.status <> 'cancelled') AS first_visit,
           t.job_class <> 'install' AS here,   -- sold and done on the same call: the sale is the sold proposal, not the whole invoice
           coalesce((SELECT cs.est_id FROM cs WHERE cs.job_id = j.id LIMIT 1),
                    (SELECT e.id FROM estimates e WHERE e.job_id = j.id AND e.status = 'accepted' ORDER BY e.accepted_at DESC NULLS LAST, e.id DESC LIMIT 1)) AS here_est
    FROM pick pk JOIN jobs j ON j.id = pk.id
    JOIN job_types t ON t.id = j.job_type_id
    LEFT JOIN install_tracking it ON it.job_id = j.id
    WHERE true
  )
  SELECT b.id, b.job_number, b.type_name, CASE WHEN b.status IN ('completed', 'invoiced', 'closed') THEN b.done_on END, c.id, c.display_name, concat_ws(', ', l.street, l.city),
         b.sp, public._emp_name(b.sp),
         coalesce(b.sale_amount, CASE WHEN b.here THEN public._est_sold_total(b.here_est) END, b.inv_sub), b.inv_sub, b.inv_owing,
         coalesce(b.commission_pct, CASE WHEN cm.amt IS NOT NULL AND coalesce(b.sale_amount, CASE WHEN b.here THEN public._est_sold_total(b.here_est) END, b.inv_sub) > 0 THEN round(cm.amt / coalesce(b.sale_amount, CASE WHEN b.here THEN public._est_sold_total(b.here_est) END, b.inv_sub) * 100, 2) END,
                  (SELECT r.pct FROM commission_rates r WHERE r.employee_id = b.sp)),
         coalesce(b.commission_amount,
                  CASE WHEN b.commission_pct IS NOT NULL THEN round(coalesce(b.sale_amount, CASE WHEN b.here THEN public._est_sold_total(b.here_est) END, b.inv_sub) * b.commission_pct / 100, 2) END,
                  CASE WHEN cm.amt IS NOT NULL AND (b.here OR b.sale_amount IS NULL OR abs(b.sale_amount - b.inv_sub) < 0.01) THEN cm.amt END,
                  CASE WHEN cm.amt IS NOT NULL AND b.inv_sub > 0 THEN round(cm.amt * b.sale_amount / b.inv_sub, 2) END,
                  round(coalesce(b.sale_amount, CASE WHEN b.here THEN public._est_sold_total(b.here_est) END, b.inv_sub) * (SELECT r.pct FROM commission_rates r WHERE r.employee_id = b.sp) / 100, 2)),
         b.inv_n > 0 AND b.inv_owing <= 0.004,
         b.prepaid_at, b.prepaid_amount, b.paid_at, b.paid_amount,
         coalesce(b.rebate_status, 'none'), b.rebate_amount, b.rebate_program, coalesce(b.financing_status, 'none'), b.financing_company, b.financing_amount,
         b.registered_at, b.registration_number,
         (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'what', coalesce(et.name, 'Equipment') || coalesce(', ' || m.name, ''),
                                                      'model', e.model_number, 'serial', e.serial_number,
                                                      'registered', EXISTS (SELECT 1 FROM warranty_coverages w WHERE w.equipment_id = e.id AND w.registration_number IS NOT NULL))
                                    ORDER BY e.id), '[]')
            FROM equipment e LEFT JOIN equipment_types et ON et.id = e.equipment_type_id LEFT JOIN manufacturers m ON m.id = e.manufacturer_id
           WHERE e.location_id = b.location_id AND e.status = 'active'
             AND (e.install_job_id = b.id OR (e.install_date BETWEEN b.done_on - 45 AND b.done_on + 15))),
         b.notes, b.it_job IS NOT NULL, b.status, b.sold_day,
         b.pick_day
  FROM base b
  LEFT JOIN LATERAL (SELECT CASE WHEN b.here THEN public._comm_est(b.sp, b.here_est) ELSE public._comm_job(b.sp, b.id) END AS amt) cm ON true
  JOIN customers c ON c.id = b.customer_id
  LEFT JOIN locations l ON l.id = b.location_id
  ORDER BY b.pick_day DESC, b.id DESC
  LIMIT 3000
$function$;
ALTER FUNCTION public.install_list(date, date) SET jit = off;
REVOKE EXECUTE ON FUNCTION public.install_list(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.install_list(date, date) TO authenticated;


-- the Sales page: these sales show as sold on a call, installed on that same call
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
               ELSE EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = jb.sales_user_id OR (jb.sales_user_id IS NULL AND (tgt.uid = jb.booked_by_user_id OR tgt.emp = jb.sold_by_employee_id))
                              OR (jb.sales_user_id IS NULL AND tgt.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))
                              OR (jb.sales_user_id IS NULL AND tgt.emp IN (SELECT es.sold_by_employee_id FROM estimates es WHERE es.job_id = jb.id))) END
    ORDER BY jb.created_at DESC LIMIT 1500),
  rows AS (
    SELECT jsonb_build_object(
      'job_id', j.id, 'job_number', j.job_number, 'status', j.status, 'summary', j.summary, 'type', t.name, 'kind', j.sales_kind, 'on_site', j.sales_on_site_at,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = j.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', (SELECT public._emp_name(va.employee_id) FROM visit_assignments va WHERE va.visit_id = v.id ORDER BY va.role = 'lead' DESC LIMIT 1),
      'sales_person', coalesce((SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = coalesce(j.sales_user_id, CASE WHEN EXISTS (SELECT 1 FROM app_users b WHERE b.id = j.booked_by_user_id AND b.role = 'sales') THEN j.booked_by_user_id END)),
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
    WHERE r.est IS NOT NULL AND t.job_class = 'install'   -- only real install jobs (not a follow-up service call)
    ORDER BY ij.id),
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
              ELSE coalesce((SELECT jsonb_agg(x ORDER BY x->>'sort' DESC) FROM (SELECT x FROM deals UNION ALL SELECT x FROM inst UNION ALL SELECT x FROM here) a), '[]'::jsonb) END
$function$;

REVOKE EXECUTE ON FUNCTION public.sales_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_list(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

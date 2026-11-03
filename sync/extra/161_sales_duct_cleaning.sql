-- Duct cleaning jobs earn commission, so they show on the Sales page as closed deals, even when sold without a proposal
-- (e.g. job 114417665). Only jobs sold by someone who earns commission (a commission rate, or a rate for a group) or a sales person.
-- A duct cleaning job already on the list (a sold proposal on it) isn't added twice. Safe to run more than once.
CREATE OR REPLACE FUNCTION public._sales_duct(p_seller bigint DEFAULT NULL, p_since date DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH me AS (SELECT public._my_employee() AS emp, public.current_app_user_id() AS uid, public._sales_boss() AS boss),
  who AS (SELECT CASE WHEN p_seller IS NULL AND me.boss THEN NULL ELSE coalesce(p_seller, me.uid) END AS seller FROM me),
  ok AS (SELECT (me.boss OR who.seller = me.uid OR EXISTS (SELECT 1 FROM sales_viewers v WHERE v.viewer_user_id = me.uid AND v.seller_user_id = who.seller)) AS ok FROM me, who),
  tgt AS (SELECT u.id AS uid, u.employee_id AS emp FROM app_users u, who WHERE u.id = who.seller),
  d AS (
    SELECT jb.*, t.name AS tname FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id
    WHERE (t.job_class = 'duct_cleaning' OR t.name ~* 'duct ?clean')
      AND jb.created_at >= coalesce(p_since::timestamptz, now() - interval '18 months')
      AND (SELECT ok FROM ok) AND jb.sold_by_employee_id IS NOT NULL
      AND (EXISTS (SELECT 1 FROM commission_rates r WHERE r.employee_id = jb.sold_by_employee_id)
           OR EXISTS (SELECT 1 FROM commission_group_rates r WHERE r.employee_id = jb.sold_by_employee_id AND r.pct > 0)
           OR EXISTS (SELECT 1 FROM app_users u WHERE u.employee_id = jb.sold_by_employee_id AND u.role = 'sales'))
      AND CASE WHEN (SELECT seller FROM who) IS NULL THEN true
               ELSE EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = jb.sales_user_id OR (jb.sales_user_id IS NULL AND tgt.emp = jb.sold_by_employee_id)) END)
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object(
      'job_id', d.id, 'job_number', d.job_number, 'status', d.status, 'summary', d.summary, 'type', d.tname, 'duct', true,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = d.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', (SELECT public._emp_name(va.employee_id) FROM visit_assignments va WHERE va.visit_id = v.id ORDER BY va.role = 'lead' DESC LIMIT 1),
      'sales_person', coalesce((SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = d.sales_user_id),
                               public._emp_name(d.sold_by_employee_id)),
      'sold_total', (SELECT sum(x.line_total) FROM invoice_lines x JOIN invoices i ON i.id = x.invoice_id
                      WHERE i.job_id = d.id AND i.status <> 'void' AND x.kit_parent_line_id IS NULL),
      'sold_on', (d.created_at AT TIME ZONE 'America/Toronto')::date,
      'stage', CASE WHEN d.status = 'cancelled' THEN 'lost' ELSE 'closed' END,
      'sort', d.created_at))
    FROM d JOIN customers c ON c.id = d.customer_id LEFT JOIN locations l ON l.id = d.location_id
    LEFT JOIN LATERAL (SELECT * FROM visits v WHERE v.job_id = d.id ORDER BY v.visit_number DESC LIMIT 1) v ON true), '[]'::jsonb) END
$function$;
REVOKE EXECUTE ON FUNCTION public._sales_duct(bigint, date) FROM PUBLIC, anon, authenticated;

-- the list plus the duct cleaning jobs not already on it
CREATE OR REPLACE FUNCTION public._sales_list_all(p_seller bigint DEFAULT NULL, p_since date DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH a AS (SELECT public._sales_list(p_seller, p_since) AS l),
  ids AS (SELECT (e->>'job_id')::bigint AS id FROM a, jsonb_array_elements(a.l) e)
  SELECT (SELECT l FROM a) || coalesce((SELECT jsonb_agg(e) FROM jsonb_array_elements(public._sales_duct(p_seller, p_since)) e
                                         WHERE (e->>'job_id')::bigint NOT IN (SELECT id FROM ids WHERE id IS NOT NULL)), '[]'::jsonb)
$function$;
REVOKE EXECUTE ON FUNCTION public._sales_list_all(bigint, date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.sales_list(p_seller bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$ SELECT public._sales_list_all(p_seller, NULL) $function$;
REVOKE EXECUTE ON FUNCTION public.sales_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_list(bigint) TO authenticated;
CREATE OR REPLACE FUNCTION public.sales_list_since(p_seller bigint DEFAULT NULL, p_since date DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$ SELECT public._sales_list_all(p_seller, p_since) $function$;
REVOKE EXECUTE ON FUNCTION public.sales_list_since(bigint, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_list_since(bigint, date) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- 99zzzL: put back the newest versions after "RUN SETUP ALL" (Oct 26) re-ran files 01-52.
-- Those files re-made older versions of 20 functions / access rules; this re-applies the newest ones
-- (and removes old versions that later files had replaced). No data is changed. Safe to run more than once.
-- F _attach_requests <- 99zm_no_equip_on_sales.sql
-- F _inv_store_pays <- 97_vista_invoices.sql
-- F _next_visit <- 99zm_no_equip_on_sales.sql
-- F _sync_after <- 99l_duplicates.sql
-- F dispatch_day <- 99t_check_in.sql
-- F has_permission <- 99ze_golive_lock.sql
-- F install_list <- 99w_all_installs.sql
-- F inv_costing <- 99b_tank_costing.sql
-- F open_balances <- 98_partner_billing.sql
-- F partner_ledger <- 99g_vista_history.sql
-- F partner_stores <- 98_partner_billing.sql
-- F pb_categories <- 63_price_books.sql
-- F pb_list <- 83_faster_pages.sql
-- F po_list <- 99v_faster_pos.sql
-- F save_my_theme <- 99zj_page_looks.sql
-- F save_partner_terms <- 97_vista_invoices.sql
-- F save_pb_item <- 99zzzJ_security_type.sql
-- F save_pb_pricing <- 99zzzG_markup_save_fix.sql
-- F search_customers <- 99zzzD_search_ampersand.sql
-- F yearly_parts <- 58_retire_and_parts.sql
-- =====================================================================
-- from 67_dispatch_map.sql
DROP FUNCTION IF EXISTS public.dispatch_day(date);

-- from 95_receivables_job_type.sql
DROP FUNCTION IF EXISTS public.open_balances(text, text);

-- from 97_vista_invoices.sql
DROP FUNCTION IF EXISTS public.partner_stores();

-- from 97_vista_invoices.sql
DROP FUNCTION IF EXISTS public.partner_ledger(bigint, text, date, date);

-- from 99s_htin_search.sql
DROP FUNCTION IF EXISTS public.search_customers(text, text, text, int, text);

-- from 99w_all_installs.sql
DROP FUNCTION IF EXISTS public.install_list(date, date);

-- from 99zm_no_equip_on_sales.sql
CREATE OR REPLACE FUNCTION public._attach_requests(p_job_id bigint)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r tech_requests; v_loc bigint; n int := 0;
BEGIN
  -- sales jobs (walk sites, estimates) never get the equipment requests
  IF EXISTS (SELECT 1 FROM jobs j JOIN job_types t ON t.id = j.job_type_id WHERE j.id = p_job_id AND t.job_class = 'sales') THEN RETURN 0; END IF;
  SELECT location_id INTO v_loc FROM jobs WHERE id = p_job_id;
  FOR r IN SELECT * FROM tech_requests WHERE location_id = v_loc AND status = 'open' ORDER BY id LOOP
    UPDATE tech_requests SET status = 'added', job_id = p_job_id, added_at = now(),
           note_id = public._job_note(p_job_id, r.body, 'tech_request')
    WHERE id = r.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $function$;

-- from 97_vista_invoices.sql
CREATE OR REPLACE FUNCTION public._inv_store_pays(p_look text, p_brand bigint, p_bill_to bigint, p_job_partner bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM partners p WHERE p.id = p_bill_to AND p.bill_to_ok)
      OR CASE WHEN p_look = 'reid' THEN false
              ELSE EXISTS (SELECT 1 FROM partners p WHERE p.customer_pays_partner
                           AND p.id = coalesce(CASE WHEN p_look = 'store' THEN p_brand END, p_bill_to, p_job_partner)) END
$$;

-- from 99zm_no_equip_on_sales.sql
CREATE OR REPLACE FUNCTION public._next_visit(p_location_id bigint, p_maintenance_only boolean)
 RETURNS TABLE(job_id bigint, scheduled_date date, job_number text, job_type text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT j.id, v.scheduled_date, j.job_number, t.name
  FROM visits v JOIN jobs j ON j.id = v.job_id JOIN job_types t ON t.id = j.job_type_id
  WHERE j.location_id = p_location_id
    AND v.status IN ('unscheduled', 'scheduled', 'dispatched')
    AND j.status NOT IN ('completed', 'cancelled')
    AND (v.scheduled_date IS NULL OR v.scheduled_date >= current_date)
    AND (NOT p_maintenance_only OR t.job_class = 'maintenance')
    AND t.job_class <> 'sales'                       -- never a sales visit
  ORDER BY v.scheduled_date NULLS LAST, v.id
  LIMIT 1
$function$;

-- from 99l_duplicates.sql
CREATE OR REPLACE FUNCTION public._sync_after()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['manufacturers', 'equipment_types', 'suppliers'] LOOP
    EXECUTE format('SELECT setval(pg_get_serial_sequence(%L, ''id''), greatest((SELECT coalesce(max(id), 1) FROM %I), '
                   '(SELECT last_value FROM %s)))', t, t, pg_get_serial_sequence(t, 'id'));
  END LOOP;
  -- anything ServiceTitan still files under a merged customer goes to the one kept
  PERFORM public._redirect_merged();
  PERFORM public.rebuild_search_index();
  DELETE FROM search_index WHERE entity_type = 'customer' AND entity_id IN (SELECT id FROM customers WHERE merged_into_id IS NOT NULL);
END $$;

-- from 99t_check_in.sql
CREATE OR REPLACE FUNCTION public.dispatch_day(p_date date)
 RETURNS TABLE(visit_id bigint, scheduled_date date, arrival_start timestamp with time zone, arrival_end timestamp with time zone, duration integer, status text, visit_number integer, job_id bigint, job_number text, job_type text, job_class text, summary text, priority text, business_unit text, customer_id bigint, customer_name text, street text, city text, postal_code text, techs jsonb, created_at timestamp with time zone, location_id bigint, lat numeric, lng numeric, province text, hood_id bigint, hood text, border_zone text, community_id bigint, community text, arrived_at timestamp with time zone, en_route_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET jit TO 'off'
AS $function$
  SELECT v.id, v.scheduled_date, v.arrival_start, v.arrival_end, v.est_duration_minutes, v.status, v.visit_number,
         j.id, j.job_number, t.name, t.job_class, j.summary, j.priority, b.name,
         c.id, c.display_name, l.street, l.city, l.postal_code,
         (SELECT coalesce(jsonb_agg(jsonb_build_object('id', va.employee_id, 'name', public._emp_name(va.employee_id), 'role', va.role)
                                    ORDER BY (va.role <> 'lead'), va.id), '[]') FROM visit_assignments va WHERE va.visit_id = v.id),
         v.created_at, l.id, l.latitude, l.longitude, l.province, h.id, h.name, l.border_zone, cm.id, cm.name, v.arrived_at, v.en_route_at
  FROM visits v
  JOIN jobs j ON j.id = v.job_id
  JOIN job_types t ON t.id = j.job_type_id
  LEFT JOIN business_units b ON b.id = j.business_unit_id
  JOIN customers c ON c.id = j.customer_id
  JOIN locations l ON l.id = j.location_id
  LEFT JOIN neighbourhoods h ON h.id = l.neighbourhood_id
  LEFT JOIN communities cm ON cm.id = l.community_id
  WHERE public.current_staff_role() IS NOT NULL
    AND ((p_date IS NOT NULL AND v.scheduled_date = p_date)
         OR (p_date IS NULL AND v.status = 'unscheduled' AND v.created_at > now() - interval '1 year'))
  ORDER BY v.arrival_start NULLS LAST, v.id
  LIMIT 1000
$function$;

-- from 99ze_golive_lock.sql
CREATE OR REPLACE FUNCTION public.has_permission(p_code text)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT coalesce(public.current_staff_role() = 'owner', false)
      OR EXISTS (SELECT 1 FROM public.user_permissions
                 WHERE app_user_id = public.current_app_user_id() AND permission_code = p_code)
      OR (p_code = 'pricebook.view' AND EXISTS (SELECT 1 FROM public.app_users WHERE id = public.current_app_user_id() AND price_book_id IS NOT NULL))
      OR (p_code IN ('calls.book', 'pricebook.view', 'customers.add') AND coalesce(public.current_staff_role() = 'sales', false))
$function$;

-- from 99w_all_installs.sql
CREATE OR REPLACE FUNCTION public.install_list(p_from date, p_to date)
 RETURNS TABLE(job_id bigint, job_number text, job_type text, completed_on date, customer_id bigint, customer_name text, address text, salesperson_id bigint, salesperson text, sale_amount numeric, invoiced numeric, owing numeric, commission_pct numeric, commission_amount numeric, customer_paid boolean, prepaid_at timestamp with time zone, prepaid_amount numeric, paid_at timestamp with time zone, paid_amount numeric, rebate_status text, rebate_amount numeric, rebate_program text, financing_status text, financing_company text, financing_amount numeric, registered_at date, registration_number text, equipment jsonb, notes text, tracked boolean, job_status text, sold_on date, date_on date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH d AS (   -- each install job's day: when it was done, or (not done yet) its booked day, else the day it was sold
    SELECT j.id, CASE WHEN j.status IN ('completed', 'invoiced', 'closed')
                      THEN coalesce(j.completed_at::date, (SELECT max(v.completed_at) FROM visits v WHERE v.job_id = j.id)::date,
                                    coalesce((SELECT e.accepted_at FROM estimates e WHERE e.id = j.sold_estimate_id), j.created_at)::date)
                      ELSE coalesce((SELECT min(v.scheduled_date) FROM visits v WHERE v.job_id = j.id AND v.status <> 'cancelled'),
                                    coalesce((SELECT e.accepted_at FROM estimates e WHERE e.id = j.sold_estimate_id), j.created_at)::date) END AS day
    FROM jobs j JOIN job_types t ON t.id = j.job_type_id AND t.job_class = 'install'
    WHERE public._can_installs() AND j.status <> 'cancelled'),
  pick AS (SELECT d.id, d.day FROM d WHERE (p_from IS NULL OR d.day >= p_from) AND (p_to IS NULL OR d.day <= p_to) ORDER BY d.day DESC, d.id DESC LIMIT 3000),
  base AS (
    SELECT j.*, t.name AS type_name, coalesce(j.completed_at, (SELECT max(v.completed_at) FROM visits v WHERE v.job_id = j.id))::date AS done_on,
           it.*, it.job_id AS it_job,
           coalesce(it.salesperson_id, (SELECT e.sold_by_employee_id FROM estimates e WHERE e.id = j.sold_estimate_id), j.sold_by_employee_id,
                    (SELECT e.sold_by_employee_id FROM estimates e WHERE e.job_id = j.id AND e.status = 'accepted' ORDER BY e.accepted_at DESC NULLS LAST LIMIT 1)) AS sp,
           (SELECT coalesce(sum(i.subtotal), 0) FROM invoices i WHERE i.job_id = j.id AND i.status NOT IN ('void', 'draft')) AS inv_sub,
           (SELECT coalesce(sum(i.balance_due) FILTER (WHERE i.not_owed_reason IS NULL), 0) FROM invoices i WHERE i.job_id = j.id AND i.status NOT IN ('void', 'draft')) AS inv_owing,
           (SELECT count(*) FROM invoices i WHERE i.job_id = j.id AND i.status NOT IN ('void', 'draft')) AS inv_n, pk.day AS pick_day,
           coalesce((SELECT e.accepted_at FROM estimates e WHERE e.id = j.sold_estimate_id), j.created_at)::date AS sold_day,
           (SELECT min(v.scheduled_date) FROM visits v WHERE v.job_id = j.id AND v.status <> 'cancelled') AS first_visit
    FROM pick pk JOIN jobs j ON j.id = pk.id
    JOIN job_types t ON t.id = j.job_type_id
    LEFT JOIN install_tracking it ON it.job_id = j.id
    WHERE true
  )
  SELECT b.id, b.job_number, b.type_name, CASE WHEN b.status IN ('completed', 'invoiced', 'closed') THEN b.done_on END, c.id, c.display_name, concat_ws(', ', l.street, l.city),
         b.sp, public._emp_name(b.sp),
         coalesce(b.sale_amount, b.inv_sub), b.inv_sub, b.inv_owing,
         coalesce(b.commission_pct, (SELECT r.pct FROM commission_rates r WHERE r.employee_id = b.sp)),
         coalesce(b.commission_amount, round(coalesce(b.sale_amount, b.inv_sub) * coalesce(b.commission_pct, (SELECT r.pct FROM commission_rates r WHERE r.employee_id = b.sp)) / 100, 2)),
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
  JOIN customers c ON c.id = b.customer_id
  LEFT JOIN locations l ON l.id = b.location_id
  ORDER BY b.pick_day DESC, b.id DESC
  LIMIT 3000
$function$;

-- from 99b_tank_costing.sql
CREATE OR REPLACE FUNCTION public.inv_costing(p_invoice bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH i AS (SELECT * FROM invoices WHERE id = p_invoice),
  j AS (SELECT jobs.* FROM jobs, i WHERE jobs.id = i.job_id),
  st AS (  -- the store that collects from the customer, if any (same rule as the invoice look)
    SELECT p.* FROM partners p, i LEFT JOIN j ON true
    WHERE p.customer_pays_partner AND i.look <> 'reid'
      AND p.id = coalesce(CASE WHEN i.look = 'store' THEN i.branding_partner_id END, j.partner_id, i.bill_to_partner_id)
    LIMIT 1),
  terms AS (SELECT pt.* FROM partner_invoice_terms pt, i WHERE pt.invoice_id = i.id),
  ln AS (
    SELECT x.id, x.description, x.quantity, x.unit_price, x.unit_cost, x.line_total, x.sequence,
           coalesce(pi.est_labour_hours, 0) * x.quantity AS hrs, pi.item_type = 'equipment' AS equip
    FROM invoice_lines x JOIN i ON x.invoice_id = i.id
    LEFT JOIN pricebook_items pi ON pi.id = x.item_id),
  sales AS (
    SELECT it.salesperson_id, concat_ws(' ', e.first_name, e.last_name) AS sp, coalesce(it.commission_pct, cr.pct) AS pct, it.commission_amount, it.sale_amount
    FROM install_tracking it JOIN j ON j.id = it.job_id
    LEFT JOIN employees e ON e.id = it.salesperson_id
    LEFT JOIN commission_rates cr ON cr.employee_id = it.salesperson_id)
  SELECT CASE WHEN NOT public._can_cost() THEN NULL ELSE jsonb_build_object(
    'can_edit_costs', i.st_id IS NULL AND public._can_invoice(i.job_id),
    'can_set_rate', public.has_permission('settings.manage'),
    'can_set_store', public.has_permission('partners.pay') OR public._can_cost(),
    'subtotal', i.subtotal, 'tax', i.tax_total, 'total', i.total,
    'techs', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', concat_ws(' ', e.first_name, e.last_name),
                'rate', nullif(coalesce(nullif(e.labour_cost_per_hour, 0), e.hourly_wage * (1 + coalesce(e.burden_pct, 0) / 100)), 0)) ORDER BY e.first_name), '[]')
              FROM employees e WHERE e.id IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id JOIN j ON j.id = v.job_id)),
    'labour_rate', (SELECT labour_cost_per_hour FROM company_settings ORDER BY id LIMIT 1),
    'est_hours', (SELECT coalesce(sum(hrs), 0) FROM ln),
    'hours', i.cost_hours,
    'vehicle', coalesce(i.cost_vehicle, (SELECT vehicle_cost_default FROM company_settings ORDER BY id LIMIT 1)),
    'vehicle_own', i.cost_vehicle IS NOT NULL,
    'other', i.cost_other, 'other_note', i.cost_other_note,
    'store', (SELECT jsonb_build_object('id', st.id, 'name', st.name,
                'cut_pct', coalesce((SELECT cut_pct FROM terms), st.default_cut_pct, 0),
                'card_fee', coalesce((SELECT card_fee FROM terms), st.default_card_fee, 0),
                'own_terms', EXISTS (SELECT 1 FROM terms)) FROM st),
    'sales', (SELECT jsonb_build_object('name', sp, 'pct', pct, 'amount', commission_amount, 'sale_amount', sale_amount) FROM sales WHERE salesperson_id IS NOT NULL),
    'lines', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'description', split_part(description, E'\n', 1), 'quantity', quantity,
                'unit_price', unit_price, 'unit_cost', unit_cost, 'line_total', line_total, 'hours', hrs, 'equip', coalesce(equip, false)) ORDER BY sequence, id), '[]') FROM ln),
    'hst', public._hst(),
    -- a partner (Vista) pays our supplier for the tank: that money and that tank aren't ours
    'partner_tank', (SELECT jsonb_build_object('partner', p.name, 'supplier', s.name, 'amount', t.amount, 'status', t.status)
                     FROM third_party_supplier_payments t JOIN partners p ON p.id = t.partner_id JOIN suppliers s ON s.id = t.supplier_id WHERE t.invoice_id = i.id)) END
  FROM i
$$;

-- from 98_partner_billing.sql
CREATE OR REPLACE FUNCTION public.open_balances(p_show text DEFAULT 'todo', p_kind text DEFAULT 'all')
RETURNS TABLE (invoice_id bigint, invoice_number text, invoice_date date, total numeric, balance numeric, status text,
               customer_id bigint, customer_name text, street text, city text, job_type text,
               plan_sale boolean, monthly_plan boolean, not_owed_reason text, checked_at timestamptz, checked_by text, marked_by text,
               over_total boolean, paid numeric, job_class text, job_partner_id bigint, job_partner text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT i.id, i.invoice_number, i.invoice_date, i.total, i.balance_due, i.status,
         c.id, c.display_name, l.street, l.city, t.name,
         EXISTS (SELECT 1 FROM invoice_lines il WHERE il.invoice_id = i.id AND il.description ILIKE '%membership%'),
         EXISTS (SELECT 1 FROM memberships m WHERE m.customer_id = c.id AND m.status = 'active' AND m.billing_frequency = 'monthly'),
         i.not_owed_reason, i.owing_checked_at, public._staff_name(i.owing_checked_by), public._staff_name(i.not_owed_by),
         i.balance_due > i.total + 0.01, i.amount_paid, t.job_class, j.partner_id, (SELECT p.name FROM partners p WHERE p.id = j.partner_id)
  FROM invoices i
  JOIN customers c ON c.id = i.customer_id
  LEFT JOIN locations l ON l.id = i.location_id
  LEFT JOIN jobs j ON j.id = i.job_id
  LEFT JOIN job_types t ON t.id = j.job_type_id
  WHERE (public.has_permission('invoices.adjust') OR public.current_staff_role() IN ('owner', 'admin', 'accounting'))
    AND i.balance_due > 0.004 AND i.status NOT IN ('void', 'draft')
    AND NOT public._inv_store_pays(i.look, i.branding_partner_id, i.bill_to_partner_id, j.partner_id)
    AND CASE coalesce(p_show, 'todo')
          WHEN 'todo'     THEN i.not_owed_reason IS NULL AND i.owing_checked_at IS NULL
          WHEN 'checked'  THEN i.not_owed_reason IS NULL AND i.owing_checked_at IS NOT NULL
          WHEN 'not_owed' THEN i.not_owed_reason IS NOT NULL
          ELSE true END
    AND CASE coalesce(p_kind, 'all')
          WHEN 'plan'    THEN EXISTS (SELECT 1 FROM invoice_lines il WHERE il.invoice_id = i.id AND il.description ILIKE '%membership%')
          WHEN 'over'    THEN i.balance_due > i.total + 0.01
          WHEN 'monthly' THEN EXISTS (SELECT 1 FROM memberships m WHERE m.customer_id = c.id AND m.status = 'active' AND m.billing_frequency = 'monthly')
          ELSE true END
  ORDER BY i.invoice_date DESC, i.id DESC
  LIMIT 2000
$$;

-- from 99g_vista_history.sql
CREATE OR REPLACE FUNCTION public.partner_ledger(p_partner bigint, p_show text, p_from date, p_to date)
RETURNS TABLE (invoice_id bigint, invoice_number text, invoice_date date, customer_id bigint, customer_name text, street text, city text,
               job_type text, total numeric, cut_pct numeric, cut_amount numeric, card_fee numeric, expected numeric, received numeric,
               still_due numeric, reference text, sent_on date, notes text, settled boolean, own_terms boolean, status text,
               account text, approval text, signed boolean, missing text[],
               supplier_amount numeric, supplier_name text, supplier_status text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH p AS (SELECT * FROM partners WHERE id = p_partner),
  inv AS (
    SELECT i.*, j.job_type_id FROM invoices i JOIN jobs j ON j.id = i.job_id
    WHERE j.partner_id = p_partner AND NOT (SELECT bill_to_ok AND NOT customer_pays_partner FROM p)
      AND i.status NOT IN ('void', 'draft') AND i.total > 0
      AND coalesce(i.look, '') <> 'reid' AND NOT (coalesce(i.look, '') = 'store' AND i.branding_partner_id IS DISTINCT FROM p_partner)
      AND NOT EXISTS (SELECT 1 FROM partners b WHERE b.id = i.bill_to_partner_id AND b.id <> p_partner AND b.bill_to_ok)
    UNION
    SELECT i.*, j.job_type_id FROM invoices i LEFT JOIN jobs j ON j.id = i.job_id
    WHERE i.bill_to_partner_id = p_partner AND i.status NOT IN ('void', 'draft') AND i.total > 0
      AND (coalesce(i.look, '') <> 'reid' OR (SELECT bill_to_ok FROM p))),
  calc AS (
    SELECT i.id, i.invoice_number, i.invoice_date, c.id AS cid, c.display_name, l.street, l.city, t.name AS jt, i.total,
           coalesce(pt.cut_pct, p.default_cut_pct, 0) AS cut, coalesce(pt.card_fee, p.default_card_fee, 0) AS card,
           coalesce((SELECT sum(rl.amount) FROM partner_remittance_lines rl WHERE rl.invoice_id = i.id), 0)
             + CASE WHEN p.bill_to_ok AND NOT p.customer_pays_partner THEN coalesce(i.amount_paid, 0)   -- a partner that pays us: every payment on the invoice counts (ServiceTitan's too)
                    ELSE coalesce((SELECT sum(pa.amount) FROM payment_applications pa JOIN payments pm ON pm.id = pa.payment_id
                                   WHERE pa.invoice_id = i.id AND pm.method = 'partner_remittance'), 0) END AS got,
           pt.reference, pt.sent_on, pt.notes, pt.settled_at IS NOT NULL OR (p.bill_to_ok AND i.not_owed_reason IS NOT NULL) AS settled, pt.invoice_id IS NOT NULL AS own,
           i.partner_account, i.authorization_number, (i.signature_png IS NOT NULL OR i.signed_at IS NOT NULL) AS signed,
           CASE WHEN p.bill_to_ok AND i.bill_to_partner_id = p.id THEN public._inv_partner_missing(i.id) ELSE '{}'::text[] END AS missing,
           coalesce(sp.amount, 0) AS sup, sp.sname, sp.status AS sstatus
    FROM inv i CROSS JOIN p
    JOIN customers c ON c.id = i.customer_id
    LEFT JOIN locations l ON l.id = i.location_id
    LEFT JOIN job_types t ON t.id = i.job_type_id
    LEFT JOIN partner_invoice_terms pt ON pt.invoice_id = i.id
    LEFT JOIN LATERAL (SELECT x.amount, s.name AS sname, x.status FROM third_party_supplier_payments x JOIN suppliers s ON s.id = x.supplier_id
                       WHERE x.invoice_id = i.id AND x.partner_id = p.id) sp ON true),
  m AS (SELECT *, total - round(total * cut / 100, 2) - card - sup AS exp FROM calc)
  SELECT id, invoice_number, invoice_date, cid, display_name, street, city, jt, total, cut, round(total * cut / 100, 2), card,
         exp, got, greatest(exp - got, 0),
         reference, sent_on, notes, settled, own,
         CASE WHEN settled OR exp - got <= 0.01 THEN 'paid' WHEN got > 0 THEN 'part' ELSE 'waiting' END,
         partner_account, authorization_number, signed, missing, sup, sname, sstatus
  FROM m
  WHERE public._can_partner_pay()
    AND (p_from IS NULL OR invoice_date >= p_from) AND (p_to IS NULL OR invoice_date <= p_to)
    AND CASE coalesce(p_show, 'waiting')
          WHEN 'waiting' THEN NOT settled AND exp - got > 0.01
          WHEN 'paid' THEN settled OR exp - got <= 0.01
          ELSE true END
  ORDER BY invoice_date DESC, id DESC
$$;

-- from 98_partner_billing.sql
CREATE OR REPLACE FUNCTION public.partner_stores()
RETURNS TABLE (id bigint, name text, default_cut_pct numeric, default_card_fee numeric, invoices bigint, still_owed numeric, pays_us boolean,
               needs_signature boolean, needs_account boolean, needs_approval boolean, terms_days integer, kind text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, p.name, p.default_cut_pct, p.default_card_fee,
         (SELECT count(*) FROM partner_ledger(p.id, 'waiting', NULL, NULL)),
         (SELECT coalesce(sum(still_due), 0) FROM partner_ledger(p.id, 'waiting', NULL, NULL)),
         p.bill_to_ok AND NOT p.customer_pays_partner,
         p.needs_signature, p.requires_partner_reference, p.requires_authorization, p.payment_terms_days,
         (SELECT t.name FROM partner_types t WHERE t.id = p.partner_type_id)
  FROM partners p
  WHERE public._can_partner_pay() AND (p.customer_pays_partner OR p.bill_to_ok) AND p.active
  ORDER BY (p.name = 'Costco') DESC, p.bill_to_ok, p.name
$$;

-- from 63_price_books.sql
CREATE OR REPLACE FUNCTION public.pb_categories()
RETURNS TABLE (id bigint, parent_id bigint, name text, active boolean, sort_order int, items bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT c.id, c.parent_id, c.name, c.active, c.sort_order,
         (SELECT count(*) FROM pricebook_item_categories ic JOIN pricebook_items p ON p.id = ic.item_id AND p.active WHERE ic.category_id = c.id)
  FROM pricebook_categories c
  WHERE public.current_staff_role() IS NOT NULL
    AND (public._pb_full()
         OR (public.has_permission('pricebook.view')
             AND (NOT EXISTS (SELECT 1 FROM user_pb_categories u WHERE u.app_user_id = public.current_app_user_id())
                  OR c.id IN (SELECT public._pb_my_cats()) OR c.id IN (SELECT public._pb_my_cat_parents()))))
    AND (public._my_book() IS NULL OR NOT EXISTS (SELECT 1 FROM price_book_categories b WHERE b.book_id = public._my_book())
         OR c.id IN (SELECT public._book_cats(public._my_book())) OR c.id IN (SELECT public._book_cat_parents(public._my_book())))
  ORDER BY c.sort_order, lower(c.name)
$$;

-- from 83_faster_pages.sql
CREATE OR REPLACE FUNCTION public.pb_list(p_search text, p_type text, p_active boolean, p_category bigint DEFAULT NULL, p_flag text DEFAULT NULL, p_limit int DEFAULT 500)
RETURNS TABLE (id bigint, item_type text, sku text, name text, description text, unit_of_measure text, unit_price numeric, unit_cost numeric,
               taxable boolean, active boolean, est_labour_hours numeric, supplier_id bigint, supplier text,
               used_12m bigint, last_used date, updated_at timestamptz,
               member_price numeric, own_member_price numeric, rule_price numeric, has_picture boolean,
               category_ids bigint[], categories text, manufacturer text, model text, kit_parts int, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  -- run with the real values each time (a fixed plan for every search was making the page slow)
  RETURN QUERY EXECUTE $q$
  WITH RECURSIVE cats AS (
    SELECT c.id FROM pricebook_categories c WHERE c.id = $4
    UNION SELECT c.id FROM pricebook_categories c JOIN cats ON c.parent_id = cats.id),
  use AS (
    SELECT il.item_id, count(*) AS n, max(i.invoice_date) AS last
    FROM invoice_lines il JOIN invoices i ON i.id = il.invoice_id
    WHERE il.item_id IS NOT NULL AND i.invoice_date > current_date - 365
    GROUP BY 1),
  s AS (SELECT rule_tolerance_pct AS tol FROM pricebook_settings LIMIT 1),
  acc AS MATERIALIZED (
    SELECT public.current_staff_role() IS NOT NULL AS staff,
           current_setting('app.pb_any_item', true) = 'on' OR public._pb_full() AS full_access,
           public.has_permission('pricebook.view') AS can_view,
           EXISTS (SELECT 1 FROM user_pb_categories u WHERE u.app_user_id = public.current_app_user_id()) AS limited,
           ARRAY(SELECT public._pb_my_cats()) AS cats,
           public._can_see_costs() AS see_costs,
           bk.id AS bk_id, bk.price_level AS bk_level, coalesce(bk.adjust_pct, 0) AS bk_adj, coalesce(bk.show_member, true) AS bk_member,
           EXISTS (SELECT 1 FROM price_book_categories c WHERE c.book_id = bk.id) AS bk_limited,
           ARRAY(SELECT public._book_cats(bk.id)) AS bk_cats
    FROM (SELECT 1) one LEFT JOIN price_books bk ON bk.id = public._my_book()),
  base AS (
    SELECT p.*, public._pb_rule_price(p.item_type, p.unit_cost) AS rule, acc.see_costs, acc.bk_member,
           CASE WHEN acc.bk_id IS NULL THEN p.unit_price ELSE round(coalesce(
             CASE acc.bk_level WHEN 'hsg' THEN (public._formula_calc(p.price_formula_id, p.unit_cost, p.formula_gp_pct, p.formula_addon_item_id) ->> 'hsg')::numeric
                               WHEN 'sales' THEN (public._formula_calc(p.price_formula_id, p.unit_cost, p.formula_gp_pct, p.formula_addon_item_id) ->> 'sales')::numeric END,
             p.unit_price) * (1 + acc.bk_adj / 100), 2) END AS book_price
    FROM pricebook_items p
    CROSS JOIN acc
    WHERE acc.staff AND NOT p.pending_new
      AND (acc.bk_id IS NULL OR NOT acc.bk_limited
           OR EXISTS (SELECT 1 FROM pricebook_item_categories ic WHERE ic.item_id = p.id AND ic.category_id = ANY (acc.bk_cats)))
      AND (acc.full_access OR (acc.can_view AND (NOT acc.limited
           OR EXISTS (SELECT 1 FROM pricebook_item_categories ic WHERE ic.item_id = p.id AND ic.category_id = ANY (acc.cats)))))
      AND (coalesce($2, 'all') = 'all' OR p.item_type = $2)
      AND ($3 IS NULL OR p.active = $3)
      AND ($4 IS NULL OR EXISTS (SELECT 1 FROM pricebook_item_categories ic WHERE ic.item_id = p.id AND ic.category_id IN (SELECT id FROM cats)))
      AND (nullif(btrim($1), '') IS NULL
           OR (SELECT bool_and(p.name ILIKE '%' || w || '%' OR p.sku ILIKE '%' || w || '%' OR coalesce(p.description, '') ILIKE '%' || w || '%'
                               OR coalesce(p.model_number, '') ILIKE '%' || w || '%' OR coalesce(p.manufacturer, '') ILIKE '%' || w || '%')
               FROM unnest(regexp_split_to_array(btrim($1), '\s+')) w))),
  -- pick the rows first (cheap), then fill in the costly columns for just those rows
  pick AS MATERIALIZED (
    SELECT b.*, coalesce(u.n, 0) AS used_n, u.last AS used_last, count(*) OVER () AS total_n
    FROM base b
    LEFT JOIN use u ON u.item_id = b.id
    CROSS JOIN s
    WHERE CASE coalesce($5, '')
            WHEN 'off_rule' THEN b.rule IS NOT NULL AND b.unit_price > 0 AND abs(b.unit_price - b.rule) > b.rule * s.tol / 100
            WHEN 'no_picture' THEN NOT EXISTS (SELECT 1 FROM pricebook_pictures pp WHERE pp.item_id = b.id)
            WHEN 'member' THEN public._pb_member_price(b.item_type, b.unit_price, b.member_price) <> b.unit_price
            WHEN 'kits' THEN EXISTS (SELECT 1 FROM pricebook_kit_items k WHERE k.parent_item_id = b.id)
            WHEN 'no_category' THEN NOT EXISTS (SELECT 1 FROM pricebook_item_categories ic WHERE ic.item_id = b.id)
            ELSE true END
    ORDER BY CASE WHEN $2 = 'equipment' THEN public._pb_equip_rank(b.name) ELSE 0 END, coalesce(u.n, 0) DESC, b.name
    LIMIT least(coalesce($6, 500), 3000))
  SELECT b.id, b.item_type, b.sku, b.name, b.description, b.unit_of_measure, b.book_price, CASE WHEN b.see_costs THEN b.unit_cost END, b.taxable, b.active,
         b.est_labour_hours, b.preferred_supplier_id, btrim(sp.name), b.used_n, b.used_last, b.updated_at,
         CASE WHEN b.bk_member THEN public._pb_member_price(b.item_type, b.book_price, CASE WHEN b.book_price = b.unit_price THEN b.member_price END) ELSE b.book_price END,
         CASE WHEN b.bk_member THEN b.member_price END, CASE WHEN b.see_costs THEN b.rule END,
         EXISTS (SELECT 1 FROM pricebook_pictures pp WHERE pp.item_id = b.id),
         (SELECT array_agg(ic.category_id ORDER BY ic.category_id) FROM pricebook_item_categories ic WHERE ic.item_id = b.id),
         (SELECT string_agg(c.name, ', ' ORDER BY c.name) FROM pricebook_item_categories ic JOIN pricebook_categories c ON c.id = ic.category_id WHERE ic.item_id = b.id),
         b.manufacturer, b.model_number,
         (SELECT count(*)::int FROM pricebook_kit_items k WHERE k.parent_item_id = b.id),
         b.total_n
  FROM pick b
  LEFT JOIN suppliers sp ON sp.id = b.preferred_supplier_id
  ORDER BY CASE WHEN $2 = 'equipment' THEN public._pb_equip_rank(b.name) ELSE 0 END, b.used_n DESC, b.name
$q$ USING p_search, p_type, p_active, p_category, p_flag, p_limit;
END $f$;

-- from 99v_faster_pos.sql
CREATE OR REPLACE FUNCTION public.po_list(p_search text, p_status text, p_supplier bigint, p_from date, p_to date, p_limit integer DEFAULT 3000)
 RETURNS TABLE(id bigint, po_number text, created_at timestamp with time zone, status text, supplier_id bigint, supplier text, purpose text, job_id bigint, job_number text, customer_id bigint, customer_name text, tech text, description text, amount numeric, lines integer, from_st boolean, total_count bigint)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  WITH q AS (SELECT nullif(btrim(p_search), '') s),
  hit AS (
    SELECT p.id, count(*) OVER () n
    FROM purchase_orders p
    JOIN suppliers s ON s.id = p.supplier_id
    LEFT JOIN jobs j ON j.id = p.job_id
    LEFT JOIN customers c ON c.id = j.customer_id, q
    WHERE public.current_staff_role() IS NOT NULL
      AND (p_from IS NULL OR p.created_at >= p_from::timestamptz)
      AND (p_to IS NULL OR p.created_at < (p_to + 1)::timestamptz)
      AND (p_supplier IS NULL OR p.supplier_id = p_supplier)
      AND CASE coalesce(p_status, 'all') WHEN 'all' THEN true
            WHEN 'open' THEN p.status IN ('draft', 'approved', 'sent', 'partially_received')
            ELSE p.status = p_status END
      AND (q.s IS NULL
           OR p.po_number ILIKE '%' || q.s || '%' OR j.job_number ILIKE '%' || q.s || '%' OR c.display_name ILIKE '%' || q.s || '%'
           OR s.name ILIKE '%' || q.s || '%' OR p.description ILIKE '%' || q.s || '%' OR p.supplier_reference ILIKE '%' || q.s || '%'
           OR EXISTS (SELECT 1 FROM purchase_order_lines l WHERE l.purchase_order_id = p.id AND l.description ILIKE '%' || q.s || '%'))
    ORDER BY p.created_at DESC, p.id DESC
    LIMIT least(coalesce(p_limit, 3000), 5000))
  SELECT p.id, p.po_number, p.created_at, p.status, s.id, btrim(s.name), p.purpose,
         j.id, j.job_number, c.id, c.display_name,
         coalesce(public._emp_name(p.ordered_by_employee_id), public._staff_name(p.created_by_user_id)), p.description,
         coalesce(p.amount, l.total), coalesce(l.n, 0)::int, p.st_id IS NOT NULL, h.n
  FROM hit h
  JOIN purchase_orders p ON p.id = h.id
  JOIN suppliers s ON s.id = p.supplier_id
  LEFT JOIN jobs j ON j.id = p.job_id
  LEFT JOIN customers c ON c.id = j.customer_id
  LEFT JOIN LATERAL (SELECT sum(x.line_total) total, count(*) n FROM purchase_order_lines x WHERE x.purchase_order_id = p.id) l ON true
  ORDER BY p.created_at DESC, p.id DESC
$function$;

-- from 99zj_page_looks.sql
CREATE OR REPLACE FUNCTION public.save_my_theme(p_prefs jsonb)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_me bigint := public.current_app_user_id(); v_pages jsonb := '{}'::jsonb; k text; v jsonb;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Only staff can save colours'; END IF;
  IF coalesce(p_prefs ->> 'id', '') NOT IN ('desert', 'classic', 'night', 'warm', 'forest') THEN RAISE EXCEPTION 'Unknown colour theme'; END IF;
  IF coalesce(p_prefs ->> 'font', 'm') NOT IN ('s', 'm', 'l', 'xl') THEN RAISE EXCEPTION 'Unknown text size'; END IF;
  IF p_prefs ? 'custom' AND (jsonb_typeof(p_prefs -> 'custom') <> 'object' OR EXISTS (
       SELECT 1 FROM jsonb_each(p_prefs -> 'custom') t
       WHERE t.key NOT IN ('desert', 'classic', 'night', 'warm', 'forest') OR jsonb_typeof(t.value) <> 'object'
          OR EXISTS (SELECT 1 FROM jsonb_each_text(t.value) c
                     WHERE c.key NOT IN ('paper', 'panel', 'blue', 'ink') OR c.value !~ '^#[0-9A-Fa-f]{6}$'))) THEN
    RAISE EXCEPTION 'One of the custom colours isn''t valid';
  END IF;
  -- one page's own look: { "<page>": { "id": theme, "font": size } }, only known themes and sizes are kept
  IF jsonb_typeof(p_prefs -> 'pages') = 'object' THEN
    FOR k, v IN SELECT * FROM jsonb_each(p_prefs -> 'pages') LOOP
      IF k ~ '^[a-z0-9-]{1,40}$' AND jsonb_typeof(v) = 'object' THEN
        v_pages := v_pages || jsonb_build_object(k, jsonb_strip_nulls(jsonb_build_object(
          'id', CASE WHEN v ->> 'id' IN ('desert', 'classic', 'night', 'warm', 'forest') THEN v ->> 'id' END,
          'font', CASE WHEN v ->> 'font' IN ('s', 'm', 'l', 'xl') THEN v ->> 'font' END)));
      END IF;
    END LOOP;
  END IF;
  UPDATE app_users SET theme_prefs = jsonb_build_object('id', p_prefs -> 'id', 'custom', coalesce(p_prefs -> 'custom', '{}'::jsonb),
                                                       'font', coalesce(p_prefs ->> 'font', 'm'), 'pages', v_pages, 'v', 2)
  WHERE id = v_me;
END $function$;

-- from 97_vista_invoices.sql
CREATE OR REPLACE FUNCTION public.save_partner_terms(p_invoice_ids bigint[], p jsonb)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n int; v_bad text;
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'You don''t have permission to change partner payments'; END IF;
  IF p ? 'cut_pct' AND nullif(p ->> 'cut_pct', '') IS NOT NULL AND (p ->> 'cut_pct')::numeric NOT BETWEEN 0 AND 60 THEN RAISE EXCEPTION 'The cut must be between 0 and 60%%'; END IF;
  IF p ? 'card_fee' AND nullif(p ->> 'card_fee', '') IS NOT NULL AND (p ->> 'card_fee')::numeric < 0 THEN RAISE EXCEPTION 'The card fee can''t be below zero'; END IF;
  IF (p ? 'cut_pct' AND coalesce(nullif(p ->> 'cut_pct', '')::numeric, 0) <> 0 OR p ? 'card_fee' AND coalesce(nullif(p ->> 'card_fee', '')::numeric, 0) <> 0)
     AND EXISTS (SELECT 1 FROM invoices i JOIN partners b ON b.id = i.bill_to_partner_id AND b.bill_to_ok AND NOT b.customer_pays_partner WHERE i.id = ANY (p_invoice_ids)) THEN
    RAISE EXCEPTION 'Vista pays the full amount: no cut or card fee'; END IF;
  IF nullif(p ->> 'sent_on', '') IS NOT NULL THEN
    SELECT i.invoice_number || ' needs the ' || array_to_string(public._inv_partner_missing(i.id), ', ') INTO v_bad
    FROM invoices i WHERE i.id = ANY (p_invoice_ids) AND cardinality(public._inv_partner_missing(i.id)) > 0 ORDER BY i.id LIMIT 1;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'Not ready to send: invoice %', v_bad; END IF;
  END IF;
  INSERT INTO partner_invoice_terms (invoice_id) SELECT unnest(p_invoice_ids) ON CONFLICT DO NOTHING;
  UPDATE partner_invoice_terms SET
    cut_pct   = CASE WHEN p ? 'cut_pct' THEN nullif(p ->> 'cut_pct', '')::numeric ELSE cut_pct END,
    card_fee  = CASE WHEN p ? 'card_fee' THEN nullif(p ->> 'card_fee', '')::numeric ELSE card_fee END,
    reference = CASE WHEN p ? 'reference' THEN nullif(btrim(p ->> 'reference'), '') ELSE reference END,
    sent_on   = CASE WHEN p ? 'sent_on' THEN nullif(p ->> 'sent_on', '')::date ELSE sent_on END,
    notes     = CASE WHEN p ? 'notes' THEN nullif(btrim(p ->> 'notes'), '') ELSE notes END,
    settled_at = CASE WHEN p ? 'settled' THEN CASE WHEN (p ->> 'settled')::boolean THEN now() END ELSE settled_at END,
    updated_by = public.current_app_user_id(), updated_at = now()
  WHERE invoice_id = ANY (p_invoice_ids);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  SELECT 'partner_invoice_terms', x, 'update', public.current_app_user_id(), p FROM unnest(p_invoice_ids) x;
  RETURN v_n;
END $$;

-- from 99zzzJ_security_type.sql
CREATE OR REPLACE FUNCTION public.save_pb_item(p_id bigint, p jsonb)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o pricebook_items; n pricebook_items; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF p ? 'name' AND nullif(btrim(p ->> 'name'), '') IS NULL THEN RAISE EXCEPTION 'The item needs a name'; END IF;
  IF p ? 'unit_price' AND (p ->> 'unit_price')::numeric < 0 THEN RAISE EXCEPTION 'The price can''t be below zero'; END IF;
  IF p ? 'unit_cost' AND (p ->> 'unit_cost')::numeric < 0 THEN RAISE EXCEPTION 'The cost can''t be below zero'; END IF;
  IF nullif(p ->> 'member_price', '') IS NOT NULL AND (p ->> 'member_price')::numeric < 0 THEN RAISE EXCEPTION 'The member price can''t be below zero'; END IF;
  IF p ? 'item_type' AND (p ->> 'item_type') NOT IN ('service', 'material', 'equipment', 'fee', 'labour', 'security') THEN RAISE EXCEPTION 'Pick parts, materials, equipment, security, fees or labour'; END IF;
  IF nullif(btrim(p ->> 'sku'), '') IS NOT NULL AND EXISTS (SELECT 1 FROM pricebook_items WHERE lower(sku) = lower(btrim(p ->> 'sku')) AND id IS DISTINCT FROM p_id AND active) THEN
    RAISE EXCEPTION 'Another item already uses the code %', btrim(p ->> 'sku');
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO pricebook_items (item_type, sku, name, description, unit_of_measure, unit_price, unit_cost, taxable, est_labour_hours, preferred_supplier_id,
                                 member_price, manufacturer, model_number)
    VALUES (coalesce(p ->> 'item_type', 'material'), coalesce(nullif(btrim(p ->> 'sku'), ''), 'NEW-' || nextval(pg_get_serial_sequence('pricebook_items', 'id'))),
            btrim(p ->> 'name'), nullif(btrim(p ->> 'description'), ''), coalesce(nullif(btrim(p ->> 'unit_of_measure'), ''), 'each'),
            coalesce((p ->> 'unit_price')::numeric, 0), coalesce((p ->> 'unit_cost')::numeric, 0), coalesce((p ->> 'taxable')::boolean, true),
            nullif(p ->> 'est_labour_hours', '')::numeric, nullif(p ->> 'preferred_supplier_id', '')::bigint,
            nullif(p ->> 'member_price', '')::numeric, nullif(btrim(p ->> 'manufacturer'), ''), nullif(btrim(p ->> 'model'), ''))
    RETURNING * INTO n;
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('pricebook_items', n.id, 'insert', v_me, to_jsonb(n));
    RETURN n.id;
  END IF;
  SELECT * INTO o FROM pricebook_items WHERE id = p_id;
  IF o.id IS NULL THEN RAISE EXCEPTION 'That item no longer exists'; END IF;
  UPDATE pricebook_items SET
    item_type = coalesce(p ->> 'item_type', item_type),
    sku = CASE WHEN nullif(btrim(p ->> 'sku'), '') IS NOT NULL THEN btrim(p ->> 'sku') ELSE sku END,
    name = coalesce(nullif(btrim(p ->> 'name'), ''), name),
    description = CASE WHEN p ? 'description' THEN nullif(btrim(p ->> 'description'), '') ELSE description END,
    unit_of_measure = coalesce(nullif(btrim(p ->> 'unit_of_measure'), ''), unit_of_measure),
    unit_price = coalesce(nullif(p ->> 'unit_price', '')::numeric, unit_price),
    unit_cost = coalesce(nullif(p ->> 'unit_cost', '')::numeric, unit_cost),
    taxable = coalesce((p ->> 'taxable')::boolean, taxable),
    active = coalesce((p ->> 'active')::boolean, active),
    est_labour_hours = CASE WHEN p ? 'est_labour_hours' THEN nullif(p ->> 'est_labour_hours', '')::numeric ELSE est_labour_hours END,
    preferred_supplier_id = CASE WHEN p ? 'preferred_supplier_id' THEN nullif(p ->> 'preferred_supplier_id', '')::bigint ELSE preferred_supplier_id END,
    member_price = CASE WHEN p ? 'member_price' THEN nullif(p ->> 'member_price', '')::numeric ELSE member_price END,
    manufacturer = CASE WHEN p ? 'manufacturer' THEN nullif(btrim(p ->> 'manufacturer'), '') ELSE manufacturer END,
    model_number = CASE WHEN p ? 'model' THEN nullif(btrim(p ->> 'model'), '') ELSE model_number END
  WHERE id = p_id RETURNING * INTO n;
  IF to_jsonb(o) - 'updated_at' IS DISTINCT FROM to_jsonb(n) - 'updated_at' THEN
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values) VALUES ('pricebook_items', p_id, 'update', v_me, to_jsonb(o), to_jsonb(n));
  END IF;
  RETURN p_id;
END $$;

-- from 99zzzG_markup_save_fix.sql
CREATE OR REPLACE FUNCTION public.save_pb_pricing(p jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o jsonb := public.pb_pricing();
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF coalesce((p ->> 'member_discount_pct')::numeric, 0) NOT BETWEEN 0 AND 90 THEN RAISE EXCEPTION 'The member discount must be between 0 and 90%%'; END IF;
  IF coalesce((p ->> 'round_to')::numeric, 0.01) NOT IN (0.01, 0.05, 0.25, 0.5, 1, 5) THEN RAISE EXCEPTION 'Round to 1 cent, 5 cents, 25 cents, 50 cents, $1 or $5'; END IF;
  UPDATE pricebook_settings SET
    member_discount_pct = coalesce((p ->> 'member_discount_pct')::numeric, 0),
    member_types = coalesce(ARRAY(SELECT jsonb_array_elements_text(p -> 'member_types')), '{}'),
    rule_tolerance_pct = coalesce((p ->> 'rule_tolerance_pct')::numeric, 5),
    round_to = coalesce((p ->> 'round_to')::numeric, 0.01),
    updated_at = now()
  WHERE id = 1;
  IF p ? 'rules' THEN
    DELETE FROM pricebook_markup_rules WHERE true;
    INSERT INTO pricebook_markup_rules (item_type, cost_from, cost_to, markup_pct)
    SELECT r ->> 'item_type', coalesce((r ->> 'cost_from')::numeric, 0), nullif(r ->> 'cost_to', '')::numeric, (r ->> 'markup_pct')::numeric
    FROM jsonb_array_elements(p -> 'rules') r
    WHERE nullif(r ->> 'markup_pct', '') IS NOT NULL;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('pricebook_settings', 1, 'update', public.current_app_user_id(), o, public.pb_pricing());
END $$;

-- from 99zzzD_search_ampersand.sql
CREATE OR REPLACE FUNCTION public.search_customers(p_name text DEFAULT NULL, p_phone text DEFAULT NULL, p_address text DEFAULT NULL,
                                                   p_limit int DEFAULT 60, p_any text DEFAULT NULL,
                                                   p_last text DEFAULT NULL, p_email text DEFAULT NULL, p_model text DEFAULT NULL)
RETURNS TABLE (customer_id bigint, display_name text, status text, street text, city text, phone text, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE
  v_name  text[] := array_remove(string_to_array(public._nm(p_name), ' '), '');   -- "&" counts as a space
  v_addr  text[] := array_remove(string_to_array(lower(btrim(coalesce(p_address, ''))), ' '), '');
  v_phone text   := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_any   text   := regexp_replace(lower(btrim(coalesce(p_any, ''))), '\s*(&amp;|&)\s*', '%', 'g');   -- "carlo & cathy" also finds "Carlo Cathy"
  v_anyd  text   := regexp_replace(coalesce(p_any, ''), '\D', '', 'g');
  v_last  text   := replace(replace(public._nm(p_last), '%', ''), '_', '\_');
  v_email text   := replace(replace(lower(btrim(coalesce(p_email, ''))), '%', ''), '_', '\_');
  v_model text   := regexp_replace(lower(coalesce(p_model, '')), '[^a-z0-9]', '', 'g');
  -- what to rank by: the name words, else the last name, else the big box
  v_key   text   := replace(replace(coalesce(nullif(public._nm(p_name), ''), nullif(public._nm(p_last), ''), nullif(public._nm(p_any), ''), ''), '%', ''), '_', '');
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Only staff can search'; END IF;
  IF cardinality(v_name) = 0 AND cardinality(v_addr) = 0 AND length(v_phone) < 3 AND length(v_any) < 2
     AND length(v_last) < 2 AND length(v_email) < 2 AND length(v_model) < 2 THEN RETURN; END IF;
  IF length(v_phone) = 11 AND left(v_phone, 1) = '1' THEN v_phone := substr(v_phone, 2); END IF;
  RETURN QUERY
  WITH name_pats AS (SELECT array_agg('%' || w || '%') AS pats FROM unnest(v_name) w),
       addr_pats AS (SELECT array_agg('%' || w || '%') AS pats FROM unnest(v_addr) w),
  name_ids AS (
    SELECT c.id FROM customers c, name_pats n WHERE cardinality(v_name) > 0 AND c.display_name ILIKE ALL (n.pats)
    UNION
    SELECT cc.customer_id FROM customer_contacts cc, name_pats n WHERE cardinality(v_name) > 0 AND cc.contact_name ILIKE ALL (n.pats)),
  -- last name: a word after the first one starts with it ("hunt" finds Ronald Hunt and Mary & Bob Hunter)
  last_ids AS (
    SELECT c.id FROM customers c WHERE length(v_last) >= 2 AND ' ' || public._nm(c.display_name) LIKE '% ' || v_last || '%'
    UNION
    SELECT cc.customer_id FROM customer_contacts cc WHERE length(v_last) >= 2 AND cc.contact_name ILIKE '% ' || v_last || '%'),
  phone_ids AS (SELECT DISTINCT cc.customer_id FROM customer_contacts cc WHERE length(v_phone) >= 3 AND cc.value_digits LIKE '%' || v_phone || '%'),
  email_ids AS (SELECT DISTINCT cc.customer_id FROM customer_contacts cc WHERE length(v_email) >= 2 AND cc.kind = 'email' AND cc.value ILIKE '%' || v_email || '%'),
  model_ids AS (   -- dashes and spaces don't matter: "TM9E 060" finds TM9E060
    SELECT DISTINCT l.customer_id FROM equipment e JOIN locations l ON l.id = e.location_id
    WHERE length(v_model) >= 2 AND (e.model_number ILIKE '%' || btrim(p_model) || '%'
       OR regexp_replace(lower(e.model_number), '[^a-z0-9]', '', 'g') LIKE '%' || v_model || '%')),
  addr_ids AS (
    SELECT DISTINCT l.customer_id FROM locations l, addr_pats a
    WHERE cardinality(v_addr) > 0
      AND concat_ws(' ', l.street, l.unit, l.city, l.postal_code, replace(coalesce(l.postal_code, ''), ' ', '')) ILIKE ALL (a.pats)),
  any_ids AS (
    SELECT DISTINCT s.customer_id FROM search_index s
    WHERE length(v_any) >= 2 AND s.customer_id IS NOT NULL
      AND (s.search_text LIKE '%' || v_any || '%'
           OR (length(v_anyd) >= 4 AND s.search_text LIKE '%' || v_anyd || '%'))),
  hits AS (
    SELECT c.id, c.display_name, c.status FROM customers c
    WHERE (cardinality(v_name) = 0 OR c.id IN (SELECT id FROM name_ids))
      AND (length(v_last) < 2 OR c.id IN (SELECT id FROM last_ids))
      AND (length(v_phone) < 3 OR c.id IN (SELECT customer_id FROM phone_ids))
      AND (length(v_email) < 2 OR c.id IN (SELECT customer_id FROM email_ids))
      AND (length(v_model) < 2 OR c.id IN (SELECT customer_id FROM model_ids))
      AND (cardinality(v_addr) = 0 OR c.id IN (SELECT customer_id FROM addr_ids))
      AND (length(v_any) < 2 OR c.id IN (SELECT customer_id FROM any_ids))
  )
  SELECT h.id, h.display_name, h.status,
         (SELECT l.street FROM locations l WHERE l.customer_id = h.id ORDER BY l.active DESC, l.id LIMIT 1),
         (SELECT l.city FROM locations l WHERE l.customer_id = h.id ORDER BY l.active DESC, l.id LIMIT 1),
         (SELECT cc.value FROM customer_contacts cc WHERE cc.customer_id = h.id AND cc.kind <> 'email'
            ORDER BY (length(v_phone) >= 3 AND cc.value_digits LIKE '%' || v_phone || '%') DESC, cc.is_primary DESC, cc.id LIMIT 1),
         count(*) OVER ()
  FROM hits h
  -- best matches first: the name starts with what's typed, then a word in it starts with it, then it's anywhere in the name
  ORDER BY CASE WHEN v_key = '' THEN 9
                WHEN public._nm(h.display_name) LIKE v_key || '%' THEN 1
                WHEN ' ' || public._nm(h.display_name) LIKE '% ' || v_key || '%' THEN 2
                WHEN public._nm(h.display_name) LIKE '%' || v_key || '%' THEN 3 ELSE 4 END,
           h.status <> 'active', lower(regexp_replace(h.display_name, '^[^[:alnum:]]+', ''))
  LIMIT least(coalesce(p_limit, 60), 200);
END $$;

-- from 58_retire_and_parts.sql
CREATE OR REPLACE FUNCTION public.yearly_parts(p_location_id bigint)
RETURNS TABLE (equipment_id bigint, label text, task text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM (
    SELECT e.id,
           coalesce(t.name, 'Equipment') || coalesce(', ' || m.name, '') || CASE WHEN public._blankish(e.model_number) THEN '' ELSE ', model ' || e.model_number END,
           CASE WHEN t.name ILIKE '%humidifier%' THEN 'Replace the humidifier pad' ELSE 'Replace the air filter' END
    FROM equipment e
    JOIN equipment_types t ON t.id = e.equipment_type_id
    LEFT JOIN manufacturers m ON m.id = e.manufacturer_id
    WHERE e.location_id = p_location_id AND e.status = 'active'
      AND t.name NOT ILIKE '%dehumid%'
      AND (t.name ILIKE '%humidifier%' OR t.name ILIKE '%filter%' OR t.name ILIKE '%air clean%' OR t.name ILIKE '%media%' OR t.name ILIKE 'hepa%')
      AND NOT EXISTS (SELECT 1 FROM location_yearly_parts y WHERE y.location_id = p_location_id AND y.active
                      AND y.replaces = CASE WHEN t.name ILIKE '%humidifier%' THEN 'humidifier' ELSE 'filter' END)
    UNION ALL
    SELECT NULL::bigint, 'picked for this home' || coalesce(': ' || nullif(btrim(y.note), ''), ''),
           'Bring ' || CASE WHEN y.quantity = 1 THEN '' ELSE trim(to_char(y.quantity, 'FM999990.##')) || ' × ' END || p.name
             || CASE WHEN p.sku IS NOT NULL AND p.sku <> p.name THEN ' [' || p.sku || ']' ELSE '' END
             || CASE y.replaces WHEN 'filter' THEN ', instead of the usual air filter' WHEN 'humidifier' THEN ', instead of the usual humidifier pad' ELSE '' END
    FROM location_yearly_parts y JOIN pricebook_items p ON p.id = y.item_id
    WHERE y.location_id = p_location_id AND y.active) x
  ORDER BY 3, 2
$$;

-- from 99l_duplicates.sql
REVOKE EXECUTE ON FUNCTION public._sync_after() FROM PUBLIC, anon, authenticated;

-- from 99t_check_in.sql
REVOKE EXECUTE ON FUNCTION public.dispatch_day(date) FROM PUBLIC, anon;

-- from 99t_check_in.sql
GRANT EXECUTE ON FUNCTION public.dispatch_day(date) TO authenticated;

-- from 99w_all_installs.sql
REVOKE EXECUTE ON FUNCTION public.install_list(date, date) FROM PUBLIC, anon;

-- from 99w_all_installs.sql
GRANT EXECUTE ON FUNCTION public.install_list(date, date) TO authenticated;

-- from 99b_tank_costing.sql
REVOKE EXECUTE ON FUNCTION public.inv_costing(bigint) FROM PUBLIC, anon;

-- from 99b_tank_costing.sql
GRANT EXECUTE ON FUNCTION public.inv_costing(bigint) TO authenticated;

-- from 98_partner_billing.sql
REVOKE EXECUTE ON FUNCTION public.open_balances(text, text) FROM PUBLIC, anon;

-- from 98_partner_billing.sql
GRANT EXECUTE ON FUNCTION public.open_balances(text, text) TO authenticated;

-- from 99g_vista_history.sql
REVOKE EXECUTE ON FUNCTION public.partner_ledger(bigint, text, date, date) FROM PUBLIC, anon;

-- from 99g_vista_history.sql
GRANT EXECUTE ON FUNCTION public.partner_ledger(bigint, text, date, date) TO authenticated;

-- from 98_partner_billing.sql
REVOKE EXECUTE ON FUNCTION public.partner_stores(), public.save_partner_rules(bigint, jsonb), public.add_partner(text, text, boolean, jsonb),
  public.partner_targets(), public.inv_bulk_bill_to(bigint[], bigint) FROM PUBLIC, anon;

-- from 98_partner_billing.sql
GRANT EXECUTE ON FUNCTION public.partner_stores(), public.save_partner_rules(bigint, jsonb), public.add_partner(text, text, boolean, jsonb),
  public.partner_targets(), public.inv_bulk_bill_to(bigint[], bigint) TO authenticated;

-- from 83_faster_pages.sql
REVOKE EXECUTE ON FUNCTION public.pb_list(text, text, boolean, bigint, text, int) FROM PUBLIC, anon;

-- from 83_faster_pages.sql
GRANT EXECUTE ON FUNCTION public.pb_list(text, text, boolean, bigint, text, int) TO authenticated;

-- from 97_vista_invoices.sql
REVOKE EXECUTE ON FUNCTION public._inv_partner_missing(bigint), public.invoice_bill_tos(), public.inv_set_bill_to(bigint, bigint),
  public.inv_set_partner_refs(bigint, text, text), public.inv_bill_info(bigint), public.partner_stores(),
  public.partner_ledger(bigint, text, date, date), public.save_partner_terms(bigint[], jsonb) FROM PUBLIC, anon;

-- from 97_vista_invoices.sql
GRANT EXECUTE ON FUNCTION public._inv_partner_missing(bigint), public.invoice_bill_tos(), public.inv_set_bill_to(bigint, bigint),
  public.inv_set_partner_refs(bigint, text, text), public.inv_bill_info(bigint), public.partner_stores(),
  public.partner_ledger(bigint, text, date, date), public.save_partner_terms(bigint[], jsonb) TO authenticated;

-- Sales commission by type of work: each sales person can have their own % for each group (Furnace, Air Conditioner,
-- Duct Cleaning…), with their usual rate (commission_rates) for anything else. An item's group comes from words in its
-- name, then its price book categories (each group's words can be changed on the Pricing control page).
-- The Installs page and invoice job costing use it. A rate typed on one install still wins. Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.commission_groups (
  id bigserial PRIMARY KEY, name text NOT NULL UNIQUE, sort_order int NOT NULL DEFAULT 0, keywords text);
CREATE TABLE IF NOT EXISTS public.commission_group_rates (
  employee_id bigint NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  group_id bigint NOT NULL REFERENCES public.commission_groups(id) ON DELETE CASCADE,
  pct numeric(5,2) NOT NULL CHECK (pct >= 0 AND pct <= 100),
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by bigint,
  PRIMARY KEY (employee_id, group_id));
ALTER TABLE public.commission_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commission_group_rates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.commission_groups, public.commission_group_rates FROM anon, authenticated;

-- the groups (checked in this order: the first match wins), with the words that put an item in them
INSERT INTO public.commission_groups (name, sort_order, keywords) VALUES
  ('Dehumidifier', 10, 'dehumid'), ('HEPA', 20, 'hepa'), ('HRV', 30, '\mhrv\M'), ('ERV', 40, '\merv\M'),
  ('Duct Cleaning', 50, 'duct ?clean'), ('Air Cleaner', 60, 'air clean|purif'), ('Humidifier', 70, 'humidif'),
  ('Condensate Pump', 80, 'condensate pump'), ('Thermostat', 90, 'thermostat'),
  ('Hot Water Tank', 100, 'water tank|water heater|hot water|tankless'), ('Air Handler', 110, 'air handler'),
  ('Heat Pump', 120, 'heat pump|mini-?split|ductless'), ('Air Conditioner', 130, 'air condition|\ma/?c\M'),
  ('Furnace', 140, 'furnace'), ('Tin', 150, '\mtin\M|sheet metal'), ('Extra Labor', 160, 'extra labou?r'),
  ('Other', 170, NULL)
ON CONFLICT (name) DO NOTHING;

-- which group an item is in: words in its name first, then its categories (closest first)
CREATE OR REPLACE FUNCTION public._comm_group(p_item bigint)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  WITH RECURSIVE cats AS (
    SELECT c.id, c.parent_id, c.name, 0 AS d FROM pricebook_item_categories pic JOIN pricebook_categories c ON c.id = pic.category_id WHERE pic.item_id = p_item
    UNION ALL SELECT p.id, p.parent_id, p.name, cats.d + 1 FROM pricebook_categories p JOIN cats ON p.id = cats.parent_id WHERE cats.d < 8),
  txt AS (SELECT name::text AS name, -1 AS d FROM pricebook_items WHERE id = p_item UNION ALL SELECT name::text, d FROM cats)
  SELECT g.id FROM txt JOIN commission_groups g ON coalesce(g.keywords, '') <> '' AND txt.name ~* g.keywords
  ORDER BY txt.d, g.sort_order LIMIT 1
$f$;

-- one person's % on one item: their rate for its group, or their usual rate
CREATE OR REPLACE FUNCTION public._comm_pct(p_emp bigint, p_item bigint)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT coalesce((SELECT pct FROM commission_group_rates WHERE employee_id = p_emp AND group_id = public._comm_group(p_item)),
                  (SELECT pct FROM commission_rates WHERE employee_id = p_emp))
$f$;

-- the commission on a job: each line (before HST) × that line's %. Uses the job's invoices, else the sold proposal option.
CREATE OR REPLACE FUNCTION public._comm_job(p_emp bigint, p_job bigint)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $f$
DECLARE v numeric; n int;
BEGIN
  IF p_emp IS NULL OR p_job IS NULL THEN RETURN NULL; END IF;
  SELECT count(*), sum(x.line_total * coalesce(CASE WHEN x.item_id IS NULL THEN (SELECT pct FROM commission_rates WHERE employee_id = p_emp) ELSE public._comm_pct(p_emp, x.item_id) END, 0) / 100)
    INTO n, v FROM invoice_lines x JOIN invoices i ON i.id = x.invoice_id
   WHERE i.job_id = p_job AND i.status NOT IN ('void', 'draft') AND x.kit_parent_line_id IS NULL;
  IF n = 0 THEN
    SELECT count(*), sum(x.line_total * coalesce(CASE WHEN x.item_id IS NULL THEN (SELECT pct FROM commission_rates WHERE employee_id = p_emp) ELSE public._comm_pct(p_emp, x.item_id) END, 0) / 100)
      INTO n, v FROM invoice_lines x JOIN invoices i ON i.id = x.invoice_id
     WHERE i.job_id = p_job AND i.status = 'draft' AND x.kit_parent_line_id IS NULL;
  END IF;
  IF n = 0 THEN
    SELECT count(*), sum(x.line_total * coalesce(CASE WHEN x.item_id IS NULL THEN (SELECT pct FROM commission_rates WHERE employee_id = p_emp) ELSE public._comm_pct(p_emp, x.item_id) END, 0) / 100)
      INTO n, v FROM estimate_lines x JOIN estimates e ON e.accepted_option_id = x.estimate_option_id
      JOIN jobs j ON j.id = p_job AND (e.id = j.sold_estimate_id OR e.id = j.from_estimate_id)
     WHERE x.parent_line_id IS NULL;
  END IF;
  RETURN CASE WHEN n > 0 THEN round(v, 2) END;
END $f$;

REVOKE EXECUTE ON FUNCTION public._comm_group(bigint), public._comm_pct(bigint, bigint), public._comm_job(bigint, bigint) FROM PUBLIC, anon, authenticated;

-- ---------- the Pricing control page: groups, words and every sales person's rates ----------
CREATE OR REPLACE FUNCTION public.comm_setup_get()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT CASE WHEN NOT public._can_installs() THEN NULL ELSE jsonb_build_object(
    'groups', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'keywords', keywords) ORDER BY sort_order, name), '[]') FROM commission_groups),
    'people', (SELECT coalesce(jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', public._emp_name(e.id), 'pct', r.pct,
                 'groups', (SELECT coalesce(jsonb_object_agg(g.group_id, g.pct), '{}') FROM commission_group_rates g WHERE g.employee_id = e.id)) ORDER BY public._emp_name(e.id)), '[]')
               FROM employees e LEFT JOIN commission_rates r ON r.employee_id = e.id
               WHERE r.pct IS NOT NULL OR EXISTS (SELECT 1 FROM commission_group_rates g WHERE g.employee_id = e.id)
                  OR e.id IN (SELECT it.salesperson_id FROM install_tracking it WHERE it.salesperson_id IS NOT NULL)
                  OR e.id IN (SELECT j.sold_by_employee_id FROM jobs j WHERE j.sold_by_employee_id IS NOT NULL AND j.created_at > now() - interval '18 months'))) END
$f$;
CREATE OR REPLACE FUNCTION public.comm_rate_set(p_emp bigint, p_group bigint, p_pct numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT public._can_installs() THEN RAISE EXCEPTION 'You don''t have permission to set commission rates'; END IF;
  IF p_pct IS NOT NULL AND (p_pct < 0 OR p_pct > 100) THEN RAISE EXCEPTION 'A rate has to be between 0 and 100%%'; END IF;
  IF p_group IS NULL THEN PERFORM public.set_commission_rate(p_emp, p_pct); RETURN; END IF;
  IF p_pct IS NULL THEN DELETE FROM commission_group_rates WHERE employee_id = p_emp AND group_id = p_group; RETURN; END IF;
  INSERT INTO commission_group_rates (employee_id, group_id, pct, updated_by) VALUES (p_emp, p_group, p_pct, public.current_app_user_id())
  ON CONFLICT (employee_id, group_id) DO UPDATE SET pct = EXCLUDED.pct, updated_at = now(), updated_by = EXCLUDED.updated_by;
END $f$;
CREATE OR REPLACE FUNCTION public.comm_group_set(p_group bigint, p_keywords text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT public._can_installs() THEN RAISE EXCEPTION 'You don''t have permission to set commission rates'; END IF;
  PERFORM 'x' ~* coalesce(nullif(btrim(p_keywords), ''), 'x');   -- a bad pattern stops here with an error
  UPDATE commission_groups SET keywords = nullif(btrim(p_keywords), '') WHERE id = p_group;
END $f$;
-- the group an item is in, and each sales person's % on it (item page job costing)
CREATE OR REPLACE FUNCTION public.comm_for_item(p_item bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE jsonb_build_object(
    'group', (SELECT name FROM commission_groups WHERE id = public._comm_group(p_item)),
    'rates', (SELECT coalesce(jsonb_object_agg(e.id, public._comm_pct(e.id, p_item)), '{}') FROM employees e
              WHERE e.id IN (SELECT employee_id FROM commission_rates UNION SELECT employee_id FROM commission_group_rates))) END
$f$;
REVOKE EXECUTE ON FUNCTION public.comm_setup_get(), public.comm_rate_set(bigint, bigint, numeric), public.comm_group_set(bigint, text), public.comm_for_item(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.comm_setup_get(), public.comm_rate_set(bigint, bigint, numeric), public.comm_group_set(bigint, text), public.comm_for_item(bigint) TO authenticated;

-- ---------- the rates Carlo gave (Oct 25): only filled in where nothing is set yet, so changes made on the page stay ----------
INSERT INTO public.commission_rates (employee_id, pct)
  SELECT e, p FROM (VALUES (12867323::bigint, 8::numeric), (2321, 8), (2315, 8), (64780756, 10), (64781134, 10)) v(e, p)
  WHERE EXISTS (SELECT 1 FROM employees WHERE id = v.e)
ON CONFLICT (employee_id) DO NOTHING;
INSERT INTO public.commission_group_rates (employee_id, group_id, pct)
  SELECT v.e, g.id, v.p FROM (VALUES
    -- Randy (both of his staff records)
    (12867323::bigint, 'Furnace', 8::numeric), (12867323, 'Air Conditioner', 5), (12867323, 'Heat Pump', 8), (12867323, 'Hot Water Tank', 6),
    (12867323, 'Duct Cleaning', 20), (12867323, 'Humidifier', 20), (12867323, 'Air Cleaner', 20), (12867323, 'HRV', 20), (12867323, 'ERV', 20),
    (12867323, 'Thermostat', 8), (12867323, 'Condensate Pump', 8), (12867323, 'Tin', 8), (12867323, 'Extra Labor', 8), (12867323, 'Other', 8),
    (12867323, 'Dehumidifier', 20), (12867323, 'Air Handler', 8), (12867323, 'HEPA', 20),
    (2321, 'Furnace', 8), (2321, 'Air Conditioner', 5), (2321, 'Heat Pump', 8), (2321, 'Hot Water Tank', 6),
    (2321, 'Duct Cleaning', 20), (2321, 'Humidifier', 20), (2321, 'Air Cleaner', 20), (2321, 'HRV', 20), (2321, 'ERV', 20),
    (2321, 'Thermostat', 8), (2321, 'Condensate Pump', 8), (2321, 'Tin', 8), (2321, 'Extra Labor', 8), (2321, 'Other', 8),
    (2321, 'Dehumidifier', 20), (2321, 'Air Handler', 8), (2321, 'HEPA', 20),
    -- Marc
    (2315, 'Furnace', 8), (2315, 'Air Conditioner', 8), (2315, 'Heat Pump', 8), (2315, 'Hot Water Tank', 8),
    (2315, 'Duct Cleaning', 15), (2315, 'Humidifier', 15), (2315, 'Air Cleaner', 15), (2315, 'HRV', 15), (2315, 'ERV', 15),
    (2315, 'Thermostat', 8), (2315, 'Condensate Pump', 8), (2315, 'Tin', 8), (2315, 'Extra Labor', 8), (2315, 'Other', 8),
    (2315, 'Dehumidifier', 15)
  ) v(e, gname, p) JOIN public.commission_groups g ON g.name = v.gname
  WHERE EXISTS (SELECT 1 FROM employees WHERE id = v.e)
ON CONFLICT (employee_id, group_id) DO NOTHING;

-- ---------- the Installs page: commission by type of work ----------
DROP FUNCTION IF EXISTS public.install_list(date, date);
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
         coalesce(b.commission_pct, CASE WHEN cm.amt IS NOT NULL AND coalesce(b.sale_amount, b.inv_sub) > 0 THEN round(cm.amt / coalesce(b.sale_amount, b.inv_sub) * 100, 2) END,
                  (SELECT r.pct FROM commission_rates r WHERE r.employee_id = b.sp)),
         coalesce(b.commission_amount,
                  CASE WHEN b.commission_pct IS NOT NULL THEN round(coalesce(b.sale_amount, b.inv_sub) * b.commission_pct / 100, 2) END,
                  CASE WHEN cm.amt IS NOT NULL AND (b.sale_amount IS NULL OR abs(b.sale_amount - b.inv_sub) < 0.01) THEN cm.amt END,
                  CASE WHEN cm.amt IS NOT NULL AND b.inv_sub > 0 THEN round(cm.amt * b.sale_amount / b.inv_sub, 2) END,
                  round(coalesce(b.sale_amount, b.inv_sub) * (SELECT r.pct FROM commission_rates r WHERE r.employee_id = b.sp) / 100, 2)),
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
  LEFT JOIN LATERAL (SELECT public._comm_job(b.sp, b.id) AS amt) cm ON true
  JOIN customers c ON c.id = b.customer_id
  LEFT JOIN locations l ON l.id = b.location_id
  ORDER BY b.pick_day DESC, b.id DESC
  LIMIT 3000
$function$;
ALTER FUNCTION public.install_list(date, date) SET jit = off;
REVOKE EXECUTE ON FUNCTION public.install_list(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.install_list(date, date) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- ---------- invoice job costing: the commission by type of work ----------
CREATE OR REPLACE FUNCTION public.inv_costing(p_invoice bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH i AS (SELECT * FROM invoices WHERE id = p_invoice),
  j AS (SELECT jobs.* FROM jobs, i WHERE jobs.id = i.job_id),
  st AS (
    SELECT p.* FROM partners p, i LEFT JOIN j ON true
    WHERE p.customer_pays_partner AND i.look <> 'reid'
      AND p.id = coalesce(CASE WHEN i.look = 'store' THEN i.branding_partner_id END, j.partner_id, i.bill_to_partner_id)
    LIMIT 1),
  terms AS (SELECT pt.* FROM partner_invoice_terms pt, i WHERE pt.invoice_id = i.id),
  ln AS (
    SELECT x.id, x.description, x.quantity, x.unit_price, x.unit_cost, x.line_total, x.sequence,
           CASE WHEN x.kit_parent_line_id IS NOT NULL THEN 0 ELSE coalesce(pi.labour_hours, pi.est_labour_hours, 0) END * x.quantity AS hrs,
           CASE WHEN x.kit_parent_line_id IS NULL AND coalesce(pi.labour_hours, pi.est_labour_hours, 0) > 0 THEN coalesce(pi.labour_techs, 1) END AS techs,
           pi.item_type = 'equipment' AS equip
    FROM invoice_lines x JOIN i ON x.invoice_id = i.id
    LEFT JOIN pricebook_items pi ON pi.id = x.item_id),
  sales AS (
    SELECT it.salesperson_id, concat_ws(' ', e.first_name, e.last_name) AS sp, coalesce(it.commission_pct, cr.pct) AS pct,
           coalesce(it.commission_amount, CASE WHEN it.commission_pct IS NULL THEN public._comm_job(it.salesperson_id, it.job_id) END) AS commission_amount,
           it.sale_amount, it.commission_pct IS NULL AND EXISTS (SELECT 1 FROM commission_group_rates g WHERE g.employee_id = it.salesperson_id) AS by_type
    FROM install_tracking it JOIN j ON j.id = it.job_id
    LEFT JOIN employees e ON e.id = it.salesperson_id
    LEFT JOIN commission_rates cr ON cr.employee_id = it.salesperson_id),
  -- what really happened: each visit's time on site (arrived to done), and who was on it
  vis AS (
    SELECT v.id, v.arrived_at, v.completed_at, extract(epoch FROM (v.completed_at - v.arrived_at)) / 3600.0 AS h
    FROM visits v JOIN j ON v.job_id = j.id
    WHERE v.arrived_at IS NOT NULL AND v.completed_at IS NOT NULL AND v.completed_at > v.arrived_at),
  vt AS (
    SELECT vis.id, vis.h, concat_ws(' ', e.first_name, e.last_name) AS nm,
           nullif(coalesce(nullif(e.labour_cost_per_hour, 0), e.hourly_wage * (1 + coalesce(e.burden_pct, 0) / 100)), 0) AS rate
    FROM vis JOIN visit_assignments va ON va.visit_id = vis.id JOIN employees e ON e.id = va.employee_id),
  stk AS (
    SELECT p.name, sum(t.quantity) AS qty, sum(t.quantity * coalesce(t.unit_cost, p.unit_cost, 0)) AS cost
    FROM inventory_transactions t JOIN j ON t.job_id = j.id JOIN pricebook_items p ON p.id = t.item_id
    WHERE t.txn_type = 'job_use' AND t.undone_at IS NULL AND t.invoice_line_id IS NULL
    GROUP BY p.name)
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
    'est_techs', (SELECT coalesce(max(techs), 1) FROM ln),
    'hours', i.cost_hours,
    'vehicle', coalesce(i.cost_vehicle, (SELECT vehicle_cost_default FROM company_settings ORDER BY id LIMIT 1)),
    'vehicle_default', (SELECT vehicle_cost_default FROM company_settings ORDER BY id LIMIT 1),
    'vehicle_own', i.cost_vehicle IS NOT NULL,
    'other', i.cost_other, 'other_note', i.cost_other_note,
    'store', (SELECT jsonb_build_object('id', st.id, 'name', st.name,
                'cut_pct', coalesce((SELECT cut_pct FROM terms), st.default_cut_pct, 0),
                'card_fee', coalesce((SELECT card_fee FROM terms), st.default_card_fee, 0),
                'own_terms', EXISTS (SELECT 1 FROM terms)) FROM st),
    'sales', (SELECT jsonb_build_object('name', sp, 'pct', pct, 'amount', commission_amount, 'sale_amount', sale_amount, 'by_type', by_type) FROM sales WHERE salesperson_id IS NOT NULL),
    'lines', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'description', split_part(description, E'\n', 1), 'quantity', quantity,
                'unit_price', unit_price, 'unit_cost', unit_cost, 'line_total', line_total, 'hours', hrs, 'equip', coalesce(equip, false)) ORDER BY sequence, id), '[]') FROM ln),
    'hst', public._hst(),
    'partner_tank', (SELECT jsonb_build_object('partner', p.name, 'supplier', s.name, 'amount', t.amount, 'status', t.status)
                     FROM third_party_supplier_payments t JOIN partners p ON p.id = t.partner_id JOIN suppliers s ON s.id = t.supplier_id WHERE t.invoice_id = i.id),
    'actual', (SELECT jsonb_build_object(
        'job_done', j.completed_at IS NOT NULL, 'completed_at', j.completed_at,
        'crew_hours', (SELECT round(sum(h)::numeric, 2) FROM vis),
        'tech_hours', (SELECT round(sum(h)::numeric, 2) FROM vt),
        'visits', (SELECT coalesce(jsonb_agg(jsonb_build_object('arrived', vis.arrived_at, 'done', vis.completed_at, 'hours', round(vis.h::numeric, 2),
                     'techs', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', vt.nm, 'rate', vt.rate)), '[]') FROM vt WHERE vt.id = vis.id)) ORDER BY vis.arrived_at), '[]') FROM vis),
        'stock', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', name, 'qty', qty, 'cost', round(cost, 2)) ORDER BY name), '[]') FROM stk),
        'stock_cost', (SELECT round(coalesce(sum(cost), 0), 2) FROM stk)) FROM j)) END
  FROM i
$$;
REVOKE EXECUTE ON FUNCTION public.inv_costing(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inv_costing(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

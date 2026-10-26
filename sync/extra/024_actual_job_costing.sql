-- One place for an item's labour hours (the Labour cost box on its page), and real job costing:
--  * set_pb_item_labour also sets the item's estimated labour hours, and items that have labour set are kept in step
--  * an invoice's estimated hours come from each item's labour (add-on kit parts don't add hours of their own)
--  * inv_costing returns what really happened: time on site from each visit's arrived / done times, per tech, and
--    stock taken out for the job that isn't on the invoice
-- Safe to run more than once.

CREATE OR REPLACE FUNCTION public.set_pb_item_labour(p_item bigint, p_hours numeric, p_techs integer, p_rate numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  UPDATE pricebook_items SET labour_hours = p_hours, labour_techs = p_techs, labour_rate = p_rate,
         est_labour_hours = coalesce(p_hours, est_labour_hours),
         labour_set_by = CASE WHEN p_hours IS NULL AND p_rate IS NULL THEN NULL ELSE public.current_app_user_id() END,
         labour_set_at = CASE WHEN p_hours IS NULL AND p_rate IS NULL THEN NULL ELSE now() END, updated_at = now()
  WHERE id = p_item;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pricebook_items', p_item, 'update', public.current_app_user_id(), jsonb_build_object('labour_hours', p_hours, 'labour_techs', p_techs, 'labour_rate', p_rate));
END $$;

-- items with labour set: their estimated hours match it (e.g. the SLP99VK070-36: 6 hours)
UPDATE public.pricebook_items SET est_labour_hours = labour_hours
WHERE labour_hours IS NOT NULL AND est_labour_hours IS DISTINCT FROM labour_hours;

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
    SELECT it.salesperson_id, concat_ws(' ', e.first_name, e.last_name) AS sp, coalesce(it.commission_pct, cr.pct) AS pct, it.commission_amount, it.sale_amount
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
    'sales', (SELECT jsonb_build_object('name', sp, 'pct', pct, 'amount', commission_amount, 'sale_amount', sale_amount) FROM sales WHERE salesperson_id IS NOT NULL),
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

DO $$ BEGIN RAISE EXCEPTION 'PROBE %', (
 SELECT jsonb_build_object(
  'tim_rate', (SELECT pct FROM commission_rates cr JOIN jobs j ON j.sold_by_employee_id = cr.employee_id WHERE j.job_number = '114417665' LIMIT 1),
  'tim_duct', (SELECT pct FROM commission_group_rates g JOIN commission_groups cg ON cg.id = g.group_id AND cg.name = 'Duct Cleaning' JOIN jobs j ON j.sold_by_employee_id = g.employee_id WHERE j.job_number = '114417665' LIMIT 1),
  'tim_user', (SELECT u.role FROM app_users u JOIN jobs j ON j.sold_by_employee_id = u.employee_id WHERE j.job_number = '114417665' LIMIT 1),
  'n_duct18', (SELECT count(*) FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id WHERE (t.job_class = 'duct_cleaning' OR t.name ~* 'duct ?clean') AND jb.created_at > now() - interval '18 months'),
  'n_sold', (SELECT count(*) FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id WHERE (t.job_class = 'duct_cleaning' OR t.name ~* 'duct ?clean') AND jb.created_at > now() - interval '18 months' AND jb.sold_by_employee_id IS NOT NULL),
  'n_earn', (SELECT count(*) FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id WHERE (t.job_class = 'duct_cleaning' OR t.name ~* 'duct ?clean') AND jb.created_at > now() - interval '18 months'
      AND (EXISTS (SELECT 1 FROM commission_rates r WHERE r.employee_id = jb.sold_by_employee_id) OR EXISTS (SELECT 1 FROM commission_group_rates r WHERE r.employee_id = jb.sold_by_employee_id))),
  'sellers', (SELECT string_agg(n || ':' || c, ', ') FROM (SELECT public._emp_name(jb.sold_by_employee_id) n, count(*) c FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id WHERE (t.job_class = 'duct_cleaning' OR t.name ~* 'duct ?clean') AND jb.created_at > now() - interval '18 months' GROUP BY 1 ORDER BY 2 DESC LIMIT 8) s),
  'inv', (SELECT sum(i.subtotal) FROM invoices i JOIN jobs j ON j.id = i.job_id WHERE j.job_number = '114417665'))::text); END $$;

DO $$ BEGIN RAISE EXCEPTION 'PROBE %', (
 SELECT jsonb_build_object(
  'fn', to_regprocedure('public._sales_duct(bigint,date)') IS NOT NULL AND to_regprocedure('public._sales_list_all(bigint,date)') IS NOT NULL,
  'wrap', (SELECT prosrc FROM pg_proc WHERE proname = 'sales_list' LIMIT 1),
  'job', (SELECT jsonb_build_object('class_ok', (t.job_class = 'duct_cleaning' OR t.name ~* 'duct ?clean'), 'recent', jb.created_at > now() - interval '18 months',
      'earner', (EXISTS (SELECT 1 FROM commission_rates r WHERE r.employee_id = jb.sold_by_employee_id) OR EXISTS (SELECT 1 FROM commission_group_rates r WHERE r.employee_id = jb.sold_by_employee_id AND r.pct > 0)
                 OR EXISTS (SELECT 1 FROM app_users u WHERE u.employee_id = jb.sold_by_employee_id AND u.role = 'sales')),
      'total', (SELECT sum(x.line_total) FROM invoice_lines x JOIN invoices i ON i.id = x.invoice_id WHERE i.job_id = jb.id AND i.status <> 'void' AND x.kit_parent_line_id IS NULL))
     FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id WHERE jb.job_number = '114417665'),
  'n_added', (SELECT count(*) FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id WHERE (t.job_class = 'duct_cleaning' OR t.name ~* 'duct ?clean') AND jb.created_at > now() - interval '18 months'
      AND (EXISTS (SELECT 1 FROM commission_rates r WHERE r.employee_id = jb.sold_by_employee_id) OR EXISTS (SELECT 1 FROM commission_group_rates r WHERE r.employee_id = jb.sold_by_employee_id AND r.pct > 0)
           OR EXISTS (SELECT 1 FROM app_users u WHERE u.employee_id = jb.sold_by_employee_id AND u.role = 'sales'))))::text); END $$;

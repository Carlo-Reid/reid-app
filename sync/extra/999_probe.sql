DO $$ BEGIN RAISE EXCEPTION 'PROBE %', (SELECT string_agg(format('J%s st=%s cr=%s done=%s V[%s] I[%s]', j.job_number, j.status, j.created_at::date, j.completed_at::date,
   (SELECT string_agg(v.scheduled_date || ':' || v.status, ',' ORDER BY v.scheduled_date) FROM visits v WHERE v.job_id = j.id),
   (SELECT string_agg(i.invoice_number || ':' || i.invoice_date || ':' || i.status, ',') FROM invoices i WHERE i.job_id = j.id)), ' | ' ORDER BY j.created_at DESC)
  FROM jobs j WHERE j.customer_id = 60584663 AND j.created_at > now() - interval '18 months'); END $$;

-- Wipe a job out for good, from the customer's page (Carlo, Nov 17, 2026: "make it so I can delete a job from the customer page and it will also
-- delete any P.O. or C.O. as well as remove it from the dispatch board and from hours techs get paid. it has to be completely wiped out").
-- job_wipe(p_id, p_dry): owners only. p_dry true = only say what would be erased (and why it can not be, if so). p_dry false = erase it:
-- the job, its calls (so it is off the dispatch board), the techs' time on it (so it is out of their paid hours), its invoices, its P.O.s,
-- its Credit Orders, its notes, photos and walk answers. What it was is kept in audit_log (one row, action 'delete', table jobs).
-- Refused: a job from ServiceTitan (the next sync would put it back, or stop on it), and a job with money on it (a payment, a bank line,
-- a partner's remittance or tank payment). A day already approved for payroll on a pay that is not final has its approval taken off.
CREATE OR REPLACE FUNCTION public.job_wipe(p_id bigint, p_dry boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE j jobs; why text; r record; v_me bigint := public.current_app_user_id();
  v_vis bigint[]; v_inv bigint[]; v_po bigint[]; v_po_st bigint[]; v_co bigint[];
  v_days jsonb; n_ts int; n_paid int; n_appr int; v_info jsonb; v_snap jsonb;
  untie text[] := ARRAY['equipment', 'estimates', 'inventory_transactions', 'jobs', 'stock_serials', 'purchase_order_lines', 'memberships',
                        'financing_applications', 'manufacturer_credits', 'manufacturer_warranty_claims', 'supplier_warranty_claims', 'partner_bookings'];
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only an owner can delete a job for good'; END IF;
  SELECT * INTO j FROM jobs WHERE id = p_id; IF j.id IS NULL THEN RAISE EXCEPTION 'That job is already gone'; END IF;
  v_vis := coalesce((SELECT array_agg(id) FROM visits WHERE job_id = p_id), '{}');
  v_inv := coalesce((SELECT array_agg(id) FROM invoices WHERE job_id = p_id), '{}');
  v_co  := coalesce((SELECT array_agg(id) FROM tank_orders WHERE job_id = p_id OR invoice_id = ANY (v_inv)), '{}');
  v_po  := coalesce((SELECT array_agg(id) FROM purchase_orders WHERE st_id IS NULL AND (job_id = p_id
             OR id IN (SELECT purchase_order_id FROM tank_orders WHERE id = ANY (v_co) AND purchase_order_id IS NOT NULL))), '{}');
  v_po_st := coalesce((SELECT array_agg(id) FROM purchase_orders WHERE st_id IS NOT NULL AND job_id = p_id), '{}');
  why := CASE
    WHEN j.st_id IS NOT NULL THEN 'it came from ServiceTitan, and ServiceTitan''s next update would put it back. Cancel it instead'
    WHEN EXISTS (SELECT 1 FROM invoices WHERE id = ANY (v_inv) AND st_id IS NOT NULL) THEN 'one of its invoices came from ServiceTitan'
    WHEN EXISTS (SELECT 1 FROM payment_applications WHERE invoice_id = ANY (v_inv)) OR EXISTS (SELECT 1 FROM payments WHERE job_id = p_id)
      THEN 'a payment is on it (take the payment off first)'
    WHEN EXISTS (SELECT 1 FROM bank_invoice_links WHERE invoice_id = ANY (v_inv)) THEN 'a bank line is attached to its invoice (take it off on the Bank page first)'
    WHEN EXISTS (SELECT 1 FROM partner_remittance_lines WHERE invoice_id = ANY (v_inv)) OR EXISTS (SELECT 1 FROM partner_remit_doc_lines WHERE invoice_id = ANY (v_inv))
      THEN 'a partner''s remittance is tied to its invoice'
    WHEN EXISTS (SELECT 1 FROM partner_submissions WHERE invoice_id = ANY (v_inv) OR job_id = p_id) THEN 'it was sent to a partner'
    WHEN EXISTS (SELECT 1 FROM third_party_supplier_payments WHERE invoice_id = ANY (v_inv) OR goes_with_invoice_id = ANY (v_inv) OR job_id = p_id)
      THEN 'a partner''s tank payment is tied to it'
    WHEN EXISTS (SELECT 1 FROM payment_plans WHERE invoice_id = ANY (v_inv)) THEN 'a payment plan is on its invoice'
    WHEN EXISTS (SELECT 1 FROM project_billing_stages WHERE invoice_id = ANY (v_inv)) OR EXISTS (SELECT 1 FROM recurring_charge_runs WHERE invoice_id = ANY (v_inv))
      THEN 'its invoice is part of a billing schedule'
    WHEN EXISTS (SELECT 1 FROM invoices x WHERE x.store_copy_of = ANY (v_inv) AND x.id <> ALL (v_inv)) THEN 'a store''s copy was made from its invoice'
  END;
  -- the techs' time on it: who, which days, and which of those days are on a pay that is already final
  SELECT count(*) INTO n_ts FROM job_timesheets t WHERE t.job_id = p_id OR t.visit_id = ANY (v_vis);
  SELECT coalesce(jsonb_agg(jsonb_build_object('user', x.uid, 'name', x.nm, 'day', x.d, 'paid', x.paid, 'approved', x.appr) ORDER BY x.d, x.nm), '[]'::jsonb),
         count(*) FILTER (WHERE x.paid), count(*) FILTER (WHERE x.appr AND NOT x.paid)
    INTO v_days, n_paid, n_appr
  FROM (SELECT DISTINCT u.id AS uid, coalesce(nullif(e.first_name, ''), u.login_email::text) AS nm, s.d,
               EXISTS (SELECT 1 FROM payroll_runs pr WHERE pr.status = 'final' AND s.d BETWEEN pr.period_from AND pr.period_to) AS paid,
               EXISTS (SELECT 1 FROM payroll_day_ok k WHERE k.user_id = u.id AND k.day = s.d) AS appr
        FROM (SELECT DISTINCT t.technician_id AS tid, (coalesce(t.arrived_on, t.dispatched_on, t.done_on) AT TIME ZONE 'America/Toronto')::date AS d
              FROM job_timesheets t WHERE (t.job_id = p_id OR t.visit_id = ANY (v_vis)) AND coalesce(t.arrived_on, t.dispatched_on, t.done_on) IS NOT NULL) s
        JOIN app_users u ON u.employee_id IS NOT NULL AND s.tid = ANY (public._payroll_emp_ids(u.employee_id))
        LEFT JOIN employees e ON e.id = u.employee_id) x;
  v_info := jsonb_build_object('ok', why IS NULL, 'why', why, 'number', j.job_number, 'status', j.status,
    'visits', cardinality(v_vis),
    'invoices', coalesce((SELECT jsonb_agg(jsonb_build_object('n', invoice_number, 'total', total, 'status', status) ORDER BY id) FROM invoices WHERE id = ANY (v_inv)), '[]'::jsonb),
    'pos', coalesce((SELECT jsonb_agg(jsonb_build_object('n', po_number, 'status', status) ORDER BY id) FROM purchase_orders WHERE id = ANY (v_po)), '[]'::jsonb),
    'pos_kept', coalesce((SELECT jsonb_agg(po_number ORDER BY id) FROM purchase_orders WHERE id = ANY (v_po_st)), '[]'::jsonb),
    'cos', coalesce((SELECT jsonb_agg(jsonb_build_object('n', coalesce(credit_number, 'CO-' || id), 'status', credit_status) ORDER BY id) FROM tank_orders WHERE id = ANY (v_co) AND payer = 'partner'), '[]'::jsonb),
    'memos', (SELECT count(*) FROM supplier_credit_memos WHERE tank_order_id = ANY (v_co)),
    'sinv', (SELECT count(*) FROM supplier_invoices WHERE purchase_order_id = ANY (v_po)),
    'received', (SELECT count(*) FROM purchase_orders WHERE id = ANY (v_po) AND status NOT IN ('draft', 'approved', 'sent', 'cancelled')),
    'timesheets', n_ts, 'days', v_days, 'paid_days', n_paid, 'approved_days', n_appr,
    'photos', (SELECT count(*) FROM attachments WHERE entity_type = 'job' AND entity_id = p_id),
    'notes', (SELECT count(*) FROM notes WHERE entity_type = 'job' AND entity_id = p_id),
    'estimates', (SELECT count(*) FROM estimates WHERE job_id = p_id));
  IF p_dry THEN RETURN v_info; END IF;
  IF why IS NOT NULL THEN RAISE EXCEPTION 'It can not be deleted: %', why; END IF;

  -- what it was, kept in the history (no pictures or signatures)
  v_snap := jsonb_build_object('job', to_jsonb(j),
    'visits', (SELECT jsonb_agg(to_jsonb(v)) FROM visits v WHERE v.id = ANY (v_vis)),
    'techs', (SELECT jsonb_agg(to_jsonb(a)) FROM visit_assignments a WHERE a.visit_id = ANY (v_vis)),
    'timesheets', (SELECT jsonb_agg(to_jsonb(t) - 'raw') FROM job_timesheets t WHERE t.job_id = p_id OR t.visit_id = ANY (v_vis)),
    'invoices', (SELECT jsonb_agg(to_jsonb(i) || jsonb_build_object('lines', (SELECT jsonb_agg(to_jsonb(l)) FROM invoice_lines l WHERE l.invoice_id = i.id))) FROM invoices i WHERE i.id = ANY (v_inv)),
    'purchase_orders', (SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object('lines', (SELECT jsonb_agg(to_jsonb(l)) FROM purchase_order_lines l WHERE l.purchase_order_id = p.id))) FROM purchase_orders p WHERE p.id = ANY (v_po)),
    'credit_orders', (SELECT jsonb_agg(to_jsonb(t)) FROM tank_orders t WHERE t.id = ANY (v_co)),
    'notes', (SELECT jsonb_agg(jsonb_build_object('at', n.created_at, 'by', n.author_name, 'body', n.body)) FROM notes n WHERE n.entity_type = 'job' AND n.entity_id = p_id));
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('jobs', p_id, 'delete', v_me, v_snap, jsonb_build_object('why', 'Wiped out for good from the customer''s page', 'what', v_info));

  -- 1. paid hours: a day approved for a pay that is not final yet has to be approved again without this job
  BEGIN
    DELETE FROM payroll_day_ok k USING jsonb_array_elements(v_days) d
     WHERE k.user_id = (d ->> 'user')::bigint AND k.day = (d ->> 'day')::date AND NOT (d ->> 'paid')::boolean;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- 2. the calls: everything that hangs on them, the techs' time, then the calls (off the dispatch board)
  IF cardinality(v_vis) > 0 THEN
    FOR r IN SELECT c.conrelid::regclass AS tbl, c.conrelid::regclass::text AS nm, a.attname AS col, a.attnotnull AS nn FROM pg_constraint c
             JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
             WHERE c.contype = 'f' AND c.confrelid = 'public.visits'::regclass AND c.conrelid <> 'public.visits'::regclass LOOP
      IF r.nm = 'follow_ups' AND NOT r.nn THEN EXECUTE format('UPDATE %s SET %I = NULL WHERE %I = ANY($1)', r.tbl, r.col, r.col) USING v_vis;
      ELSE EXECUTE format('DELETE FROM %s WHERE %I = ANY($1)', r.tbl, r.col) USING v_vis; END IF;
    END LOOP;
    DELETE FROM on_way_texts WHERE visit_id = ANY (v_vis);
    DELETE FROM on_way_delays WHERE visit_id = ANY (v_vis);
  END IF;
  DELETE FROM online_bookings WHERE job_id = p_id OR visit_id = ANY (v_vis);
  DELETE FROM job_timesheets WHERE job_id = p_id OR visit_id = ANY (v_vis);
  DELETE FROM visits WHERE job_id = p_id;

  -- 3. Credit Orders (a Credit Memo made from the supplier's own credit paper stays, untied)
  UPDATE supplier_credit_memos SET tank_order_id = NULL WHERE tank_order_id = ANY (v_co);
  DELETE FROM tank_orders WHERE id = ANY (v_co);

  -- 4. P.O.s (a supplier's invoice that was matched to one stays, with no P.O.)
  IF cardinality(v_po) > 0 THEN
    UPDATE supplier_credit_memos SET purchase_order_id = NULL WHERE purchase_order_id = ANY (v_po);
    UPDATE supplier_credit_memos SET replaced_po_id = NULL WHERE replaced_po_id = ANY (v_po);
    FOR r IN SELECT c.conrelid::regclass AS tbl, a.attname AS col, a.attnotnull AS nn, c.confdeltype AS del FROM pg_constraint c
             JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
             WHERE c.contype = 'f' AND c.confrelid = 'public.purchase_orders'::regclass AND c.confdeltype NOT IN ('c', 'n') LOOP
      IF r.nn THEN EXECUTE format('DELETE FROM %s WHERE %I = ANY($1)', r.tbl, r.col) USING v_po;
      ELSE EXECUTE format('UPDATE %s SET %I = NULL WHERE %I = ANY($1)', r.tbl, r.col, r.col) USING v_po; END IF;
    END LOOP;
    DELETE FROM search_index WHERE entity_type = 'purchase_order' AND entity_id = ANY (v_po);
    DELETE FROM purchase_orders WHERE id = ANY (v_po);
  END IF;
  UPDATE purchase_orders SET job_id = NULL WHERE id = ANY (v_po_st);

  -- 5. invoices (their lines and sent copies go with them)
  IF cardinality(v_inv) > 0 THEN
    DELETE FROM supplier_invoice_customer_links WHERE invoice_id = ANY (v_inv);
    DELETE FROM partner_statement_matches WHERE invoice_id = ANY (v_inv);
    UPDATE partner_supplier_credits SET invoice_id = NULL WHERE invoice_id = ANY (v_inv);
    DELETE FROM invoice_line_cost_skips WHERE invoice_id = ANY (v_inv);
    DELETE FROM search_index WHERE entity_type = 'invoice' AND entity_id = ANY (v_inv);
    DELETE FROM invoices WHERE store_copy_of = ANY (v_inv);
    DELETE FROM invoices WHERE id = ANY (v_inv);
  END IF;

  -- 6. everything else that points at the job
  FOR r IN SELECT c.conrelid::regclass AS tbl, c.conrelid::regclass::text AS nm, a.attname AS col, a.attnotnull AS nn FROM pg_constraint c
           JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
           WHERE c.contype = 'f' AND c.confrelid = 'public.jobs'::regclass LOOP
    IF r.nm = ANY (untie) AND NOT r.nn THEN EXECUTE format('UPDATE %s SET %I = NULL WHERE %I = $1', r.tbl, r.col, r.col) USING p_id;
    ELSE EXECUTE format('DELETE FROM %s WHERE %I = $1', r.tbl, r.col) USING p_id; END IF;
  END LOOP;
  DELETE FROM comm_sale_jobs_cache WHERE job_id = p_id OR sale_job_id = p_id;
  DELETE FROM install_holds WHERE job_id = p_id;
  DELETE FROM job_file_scan WHERE job_id = p_id;
  DELETE FROM sale_notes WHERE job_id = p_id;
  DELETE FROM sinv_job_suggest WHERE job_id = p_id;
  DELETE FROM practice_bookings WHERE job_id = p_id;
  DELETE FROM install_checks WHERE job_id = p_id;
  DELETE FROM walk_results WHERE job_id = p_id;
  DELETE FROM vista_rental_picks WHERE kind = 'job' AND ref_id = p_id;
  DELETE FROM attachments WHERE entity_type = 'job' AND entity_id = p_id;
  DELETE FROM notes WHERE entity_type = 'job' AND entity_id = p_id;
  DELETE FROM search_index WHERE entity_type = 'job' AND entity_id = p_id;
  DELETE FROM jobs WHERE id = p_id;
  DELETE FROM notes WHERE entity_type = 'job' AND entity_id = p_id;   -- a note a trigger wrote while it was going
  RETURN v_info || jsonb_build_object('done', true);
END $function$;
REVOKE EXECUTE ON FUNCTION public.job_wipe(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.job_wipe(bigint, boolean) TO authenticated;
NOTIFY pgrst, 'reload schema';

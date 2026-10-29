-- Delete a job from the customer page (Section 5) when it was never done: scheduled, cancelled, on hold, new.
-- Not a completed job, and not one with an invoice. Owners and dispatchers can delete any of these; others only jobs they booked.
-- Anything else that points at the job is cleared: visits (and what hangs off them) and job notes go; optional links are emptied.
CREATE OR REPLACE FUNCTION public.job_delete(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE j jobs; v_role text := public.current_staff_role(); r record; v_visits bigint[]; v_has boolean;
BEGIN
  IF v_role IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT * INTO j FROM jobs WHERE id = p_id; IF j.id IS NULL THEN RAISE EXCEPTION 'That job is already gone'; END IF;
  IF j.status = 'completed' OR j.completed_at IS NOT NULL THEN RAISE EXCEPTION 'This job is done, so it stays in the history.'; END IF;
  IF EXISTS (SELECT 1 FROM invoices WHERE job_id = p_id) THEN RAISE EXCEPTION 'This job has an invoice, so it can''t be deleted.'; END IF;
  IF v_role <> 'owner' AND NOT public.has_permission('calls.dispatch')
     AND j.booked_by_user_id IS DISTINCT FROM public.current_app_user_id() AND j.sales_user_id IS DISTINCT FROM public.current_app_user_id() THEN
    RAISE EXCEPTION 'You can only delete jobs you booked'; END IF;
  SELECT array_agg(id) INTO v_visits FROM visits WHERE job_id = p_id;
  BEGIN
    -- what hangs off the visits
    IF v_visits IS NOT NULL THEN
      FOR r IN SELECT c.conrelid::regclass AS tbl, a.attname AS col, a.attnotnull AS nn FROM pg_constraint c
               JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
               WHERE c.contype = 'f' AND c.confrelid = 'public.visits'::regclass AND c.conrelid <> 'public.visits'::regclass LOOP
        IF r.nn THEN EXECUTE format('DELETE FROM %s WHERE %I = ANY($1)', r.tbl, r.col) USING v_visits;
        ELSE EXECUTE format('UPDATE %s SET %I = NULL WHERE %I = ANY($1)', r.tbl, r.col, r.col) USING v_visits; END IF;
      END LOOP;
    END IF;
    -- what points at the job
    FOR r IN SELECT c.conrelid::regclass AS tbl, a.attname AS col, a.attnotnull AS nn FROM pg_constraint c
             JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
             WHERE c.contype = 'f' AND c.confrelid = 'public.jobs'::regclass LOOP
      IF r.tbl::text ~ '(payment|purchase_order|invoice|supplier)' THEN
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s WHERE %I = $1)', r.tbl, r.col) INTO v_has USING p_id;
        IF v_has THEN RAISE EXCEPTION 'This job has % on it, so it can''t be deleted. Cancel it instead.', replace(r.tbl::text, '_', ' '); END IF;
      END IF;
      IF r.nn THEN EXECUTE format('DELETE FROM %s WHERE %I = $1', r.tbl, r.col) USING p_id;
      ELSE EXECUTE format('UPDATE %s SET %I = NULL WHERE %I = $1', r.tbl, r.col, r.col) USING p_id; END IF;
    END LOOP;
    DELETE FROM notes WHERE entity_type = 'job' AND entity_id = p_id;
    DELETE FROM jobs WHERE id = p_id;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'This job is linked to something that has to stay (%), so it can''t be deleted. Cancel it instead.', SQLERRM;
  END;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('jobs', p_id, 'delete', public.current_app_user_id(),
    jsonb_build_object('number', j.job_number, 'customer', j.customer_id, 'status', j.status, 'st_id', j.st_id));
END $function$;
REVOKE EXECUTE ON FUNCTION public.job_delete(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.job_delete(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

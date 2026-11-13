-- Another invoice on the same job, with its own answer to "who pays for the tank" (Carlo, Nov 13, 2026:
-- "add a button that lets you add another invoice to this job and choose if vista pays or we pay").
ALTER TABLE invoices ADD COLUMN IF NOT EXISTS tank_payer text;

CREATE OR REPLACE FUNCTION public.job_add_invoice(p_job bigint, p_payer text)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE j jobs; v_id bigint; v_bu bigint;
BEGIN
  SELECT * INTO j FROM jobs WHERE id = p_job;
  IF j.id IS NULL THEN RAISE EXCEPTION 'That job no longer exists'; END IF;
  IF NOT public._can_invoice(p_job) THEN RAISE EXCEPTION 'You can only invoice the jobs you''re on'; END IF;
  IF p_payer IS NULL OR p_payer NOT IN ('reid', 'partner') THEN RAISE EXCEPTION 'Pick who pays: us or the partner'; END IF;
  v_bu := coalesce(j.business_unit_id, (SELECT id FROM business_units ORDER BY id LIMIT 1));
  INSERT INTO invoices (invoice_number, job_id, customer_id, location_id, business_unit_id, channel, bill_to_type, status, invoice_date,
                        payment_terms_days, collect_on_site, created_by_user_id, tank_payer)
  VALUES ('R' || nextval('app_invoice_seq'), j.id, j.customer_id, j.location_id, v_bu, 'job', 'customer', 'draft', current_date,
          0, true, public.current_app_user_id(), p_payer)
  RETURNING id INTO v_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('invoices', v_id, 'insert', public.current_app_user_id(), jsonb_build_object('job', j.job_number, 'started', true, 'another_invoice', true, 'tank_payer', p_payer));
  RETURN v_id;
END $function$;
GRANT EXECUTE ON FUNCTION public.job_add_invoice(bigint, text) TO authenticated;

-- the invoice's own answer wins over the job's, in the three places that read it
DO $do$
DECLARE r record; d text;
BEGIN
  FOR r IN SELECT p.oid, p.proname FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('tank_order_for', 'tank_order_make', 'inv_partner_rule') LOOP
    d := pg_get_functiondef(r.oid);
    IF d NOT LIKE '%i.tank_payer%' THEN
      d := replace(d, 'j.tank_payer', 'coalesce(i.tank_payer, j.tank_payer)');
      EXECUTE d;
    END IF;
  END LOOP;
END $do$;

-- 99zzzQ: change the day a commission was paid. Also runs every night from sync/extra/034_commission_payroll.sql. Safe to run more than once.
-- change the day a commission was paid (or paid early)
CREATE OR REPLACE FUNCTION public.set_commission_paid_date(p_job_id bigint, p_date date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o install_tracking; n install_tracking; v_me bigint := public.current_app_user_id(); v_ts timestamptz;
BEGIN
  IF NOT public._can_installs() THEN RAISE EXCEPTION 'You don''t have permission to pay commissions'; END IF;
  IF p_date IS NULL THEN RAISE EXCEPTION 'Pick the day it was paid'; END IF;
  IF p_date > (now() AT TIME ZONE 'America/Toronto')::date + 1 THEN RAISE EXCEPTION 'The paid day can''t be in the future (put it on payroll instead)'; END IF;
  SELECT * INTO o FROM install_tracking WHERE job_id = p_job_id FOR UPDATE;
  IF o.job_id IS NULL OR (o.paid_at IS NULL AND o.prepaid_at IS NULL) THEN RAISE EXCEPTION 'This commission isn''t paid yet'; END IF;
  v_ts := (p_date::timestamp + interval '12 hours') AT TIME ZONE 'America/Toronto';
  UPDATE install_tracking SET paid_at = CASE WHEN paid_at IS NOT NULL THEN v_ts ELSE paid_at END,
         prepaid_at = CASE WHEN paid_at IS NULL THEN v_ts ELSE prepaid_at END,
         payroll_on = CASE WHEN payroll_on IS NOT NULL AND paid_at IS NOT NULL THEN p_date ELSE payroll_on END,
         updated_at = now(), updated_by = v_me
  WHERE job_id = p_job_id RETURNING * INTO n;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('install_tracking', p_job_id, 'update', v_me, jsonb_build_object('paid_at', o.paid_at, 'prepaid_at', o.prepaid_at),
          jsonb_build_object('paid_at', n.paid_at, 'prepaid_at', n.prepaid_at));
END $$;
REVOKE EXECUTE ON FUNCTION public.set_commission_paid_date(bigint, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_commission_paid_date(bigint, date) TO authenticated;
NOTIFY pgrst, 'reload schema';

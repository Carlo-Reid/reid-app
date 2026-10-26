-- Commission payroll: mark an install's commission for payroll on a pay day; on that day it becomes paid
-- (paid date = the pay day, amount = the commission when it was marked). Runs every night. Safe to run more than once.
ALTER TABLE public.install_tracking ADD COLUMN IF NOT EXISTS payroll_on date;
ALTER TABLE public.install_tracking ADD COLUMN IF NOT EXISTS payroll_amount numeric(12,2);
ALTER TABLE public.install_tracking ADD COLUMN IF NOT EXISTS payroll_by bigint REFERENCES public.app_users(id);

-- pay days that have come: the commission is paid
CREATE OR REPLACE FUNCTION public._payroll_due()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n int;
BEGIN
  WITH d AS (
    UPDATE install_tracking t SET paid_at = (t.payroll_on::timestamp + interval '12 hours') AT TIME ZONE 'America/Toronto',
           paid_amount = t.payroll_amount, paid_by = t.payroll_by, updated_at = now()
    WHERE t.payroll_on IS NOT NULL AND t.payroll_on <= (now() AT TIME ZONE 'America/Toronto')::date AND t.paid_at IS NULL AND t.payroll_amount IS NOT NULL
    RETURNING t.job_id, t.payroll_on, t.payroll_amount)
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  SELECT 'install_tracking', d.job_id, 'update', NULL, jsonb_build_object('paid_on_payroll', d.payroll_on, 'paid_amount', d.payroll_amount) FROM d;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION public._payroll_due() FROM PUBLIC, anon, authenticated;

-- put one install's commission on a pay day (p_date null = take it off payroll)
CREATE OR REPLACE FUNCTION public.set_commission_payroll(p_job_id bigint, p_date date, p_amount numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o install_tracking; n install_tracking; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT public._can_installs() THEN RAISE EXCEPTION 'You don''t have permission to pay commissions'; END IF;
  IF p_date IS NOT NULL AND (p_amount IS NULL OR p_amount < 0) THEN RAISE EXCEPTION 'This commission has no amount yet'; END IF;
  INSERT INTO install_tracking (job_id) VALUES (p_job_id) ON CONFLICT (job_id) DO NOTHING;
  SELECT * INTO o FROM install_tracking WHERE job_id = p_job_id FOR UPDATE;
  IF o.paid_at IS NOT NULL THEN RAISE EXCEPTION 'This commission is already paid'; END IF;
  UPDATE install_tracking SET payroll_on = p_date, payroll_amount = CASE WHEN p_date IS NULL THEN NULL ELSE p_amount END,
         payroll_by = CASE WHEN p_date IS NULL THEN NULL ELSE v_me END, updated_at = now(), updated_by = v_me
  WHERE job_id = p_job_id RETURNING * INTO n;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('install_tracking', p_job_id, 'update', v_me, jsonb_build_object('payroll_on', o.payroll_on, 'payroll_amount', o.payroll_amount),
          jsonb_build_object('payroll_on', n.payroll_on, 'payroll_amount', n.payroll_amount));
  PERFORM public._payroll_due();   -- a pay day of today (or before) is paid right away
END $$;
REVOKE EXECUTE ON FUNCTION public.set_commission_payroll(bigint, date, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_commission_payroll(bigint, date, numeric) TO authenticated;

-- the installs on payroll (for the Sales page); pays any whose day has come first
CREATE OR REPLACE FUNCTION public.commission_payroll()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public._can_installs() THEN RETURN '[]'::jsonb; END IF;
  PERFORM public._payroll_due();
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('job_id', job_id, 'payroll_on', payroll_on, 'payroll_amount', payroll_amount))
                   FROM install_tracking WHERE payroll_on IS NOT NULL), '[]'::jsonb);
END $$;
REVOKE EXECUTE ON FUNCTION public.commission_payroll() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.commission_payroll() TO authenticated;

SELECT public._payroll_due() AS paid_on_payroll_today;
NOTIFY pgrst, 'reload schema';

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

-- =====================================================================
-- Improvement 10: the Today page (owners): one look in the morning.
-- Yesterday's invoices and payments, today's calls, money owing, estimates, what customers opened,
-- EFT lists waiting for approval, open tasks, and anything that broke. Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.owner_today()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '30s' AS $$
DECLARE
  tz text := coalesce((SELECT nullif(timezone, '') FROM company_settings ORDER BY id LIMIT 1), 'America/Toronto');
  today date := (now() AT TIME ZONE tz)::date;
  yday date := today - 1;
  y0 timestamptz := (yday::timestamp AT TIME ZONE tz); y1 timestamptz := (today::timestamp AT TIME ZONE tz);
  m0 date := date_trunc('month', today)::date;
  v jsonb := '{}'; x jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RETURN NULL; END IF;
  v := v || jsonb_build_object('today', today, 'yesterday', yday);
  SELECT jsonb_build_object('n', count(*), 'total', coalesce(sum(total), 0)) INTO x FROM invoices WHERE invoice_date = yday AND status <> 'draft';
  v := v || jsonb_build_object('invoiced', x);
  SELECT jsonb_build_object('month', coalesce(sum(total) FILTER (WHERE invoice_date >= m0), 0),
                            'last_month', coalesce(sum(total) FILTER (WHERE invoice_date >= (m0 - interval '1 month')::date AND invoice_date <= (today - interval '1 month')::date), 0))
    INTO x FROM invoices WHERE invoice_date >= (m0 - interval '1 month')::date AND status <> 'draft';
  v := v || jsonb_build_object('month', x);
  SELECT jsonb_build_object('n', count(*), 'total', coalesce(sum(amount), 0)) INTO x FROM payments WHERE received_on = yday AND coalesce(status, 'succeeded') = 'succeeded';
  v := v || jsonb_build_object('paid', x);
  SELECT jsonb_build_object('all', coalesce(sum(balance_due), 0), 'over90', coalesce(sum(balance_due) FILTER (WHERE current_date - coalesce(due_date, invoice_date) >= 90), 0),
                            'over90_n', count(*) FILTER (WHERE current_date - coalesce(due_date, invoice_date) >= 90))
    INTO x FROM invoices WHERE status IN ('posted', 'partially_paid') AND balance_due > 0.004 AND bad_debt_at IS NULL AND not_owed_at IS NULL;
  v := v || jsonb_build_object('owing', x);
  SELECT jsonb_build_object('n', count(*), 'done', count(*) FILTER (WHERE status IN ('completed', 'done') OR completed_at IS NOT NULL),
                            'cancelled', count(*) FILTER (WHERE status IN ('cancelled', 'canceled')))
    INTO x FROM visits WHERE scheduled_date = today;
  v := v || jsonb_build_object('calls', x);
  SELECT jsonb_build_object('sent', count(*) FILTER (WHERE sent_at >= y0 AND sent_at < y1), 'sold', count(*) FILTER (WHERE accepted_at >= y0 AND accepted_at < y1),
                            'open30', count(*) FILTER (WHERE status IN ('sent', 'draft') AND cancelled_at IS NULL AND coalesce(sent_at, created_at) < now() - interval '30 days'))
    INTO x FROM estimates;
  v := v || jsonb_build_object('estimates', x);
  SELECT jsonb_build_object('sent', count(*), 'opened', count(*) FILTER (WHERE opened_at IS NOT NULL), 'viewed', count(*) FILTER (WHERE viewed_at IS NOT NULL),
                            'forwarded', count(*) FILTER (WHERE forwarded OR maybe_forwarded), 'failed', count(*) FILTER (WHERE status = 'failed'))
    INTO x FROM doc_sends WHERE sent_at >= y0 AND sent_at < y1;
  v := v || jsonb_build_object('sends', x);
  v := v || jsonb_build_object('eft_waiting', (SELECT count(*) FROM pap_inbox WHERE status = 'waiting'));
  v := v || jsonb_build_object('tasks', (SELECT jsonb_build_object('open', count(*), 'mine', count(*) FILTER (WHERE coalesce(assigned_to, app_user_id) = public.current_app_user_id()))
                                         FROM follow_ups WHERE done_at IS NULL AND completed_at IS NULL));
  v := v || jsonb_build_object('no_cell', (SELECT count(*) FROM app_users u JOIN employees e ON e.id = u.employee_id
                                           WHERE u.active AND u.deleted_at IS NULL AND coalesce(e.active, true) AND nullif(btrim(e.mobile_phone), '') IS NULL));
  v := v || jsonb_build_object('test_mode', (SELECT nullif(btrim(send_test_to), '') FROM company_settings ORDER BY id LIMIT 1));
  IF to_regclass('public.client_errors') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.client_errors WHERE at > now() - interval ''24 hours''' INTO x; v := v || jsonb_build_object('errors', x);
  END IF;
  IF to_regclass('public.st_sync_runs') IS NOT NULL THEN
    BEGIN
      EXECUTE 'SELECT to_jsonb(r) FROM (SELECT id, source, started_at, finished_at, ok, left(error, 300) AS error FROM public.st_sync_runs ORDER BY id DESC LIMIT 1) r' INTO x; v := v || jsonb_build_object('sync', x);
    EXCEPTION WHEN others THEN NULL; END;
  END IF;
  IF to_regprocedure('public.schedule_status()') IS NOT NULL THEN
    EXECUTE 'SELECT public.schedule_status()' INTO x; v := v || jsonb_build_object('timer', x - 'runs');
  END IF;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION public.owner_today() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_today() TO authenticated;

NOTIFY pgrst, 'reload schema';

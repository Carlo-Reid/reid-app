-- 99zzzR: quick list of commission paid / payroll days for the Sales page. Also runs every night from sync/extra/034. Safe to run more than once.
-- paid / paid early / payroll days of every install's commission: a quick read for the Sales page
-- (the commission amounts take longer to work out and come after). Pays any whose pay day has come first.
CREATE OR REPLACE FUNCTION public.commission_paid_list()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public._can_installs() THEN RETURN '[]'::jsonb; END IF;
  PERFORM public._payroll_due();
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('job_id', job_id, 'paid_at', paid_at, 'paid_amount', paid_amount, 'prepaid_at', prepaid_at,
                          'prepaid_amount', prepaid_amount, 'payroll_on', payroll_on, 'payroll_amount', payroll_amount))
                   FROM install_tracking WHERE paid_at IS NOT NULL OR prepaid_at IS NOT NULL OR payroll_on IS NOT NULL), '[]'::jsonb);
END $$;
REVOKE EXECUTE ON FUNCTION public.commission_paid_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.commission_paid_list() TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Nov 13 (Carlo): a call booked from the invoice's Book a tech keeps the length that was booked (a 1 hour walk, not the job type's 2 hours),
-- and the tech's call page knows which jobs have their invoice finished with nothing to collect.
CREATE OR REPLACE FUNCTION public.set_call_length(p_visit_id bigint, p_minutes int, p_purpose text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (public.has_permission('calls.book') OR public.has_permission('calls.dispatch')) THEN RAISE EXCEPTION 'You don''t have permission to change calls'; END IF;
  IF p_minutes IS NOT NULL AND (p_minutes < 15 OR p_minutes > 1440) THEN RAISE EXCEPTION 'That length is not right'; END IF;
  UPDATE visits SET est_duration_minutes = coalesce(p_minutes, est_duration_minutes),
                    visit_purpose = coalesce(nullif(btrim(left(p_purpose, 300)), ''), visit_purpose)
  WHERE id = p_visit_id AND status NOT IN ('completed', 'cancelled');
END $function$;
REVOKE EXECUTE ON FUNCTION public.set_call_length(bigint, int, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_call_length(bigint, int, text) TO authenticated;

-- jobs whose invoice is finished and has nothing for the tech to collect (a partner pays it, it was paid at the store, or nothing is owing)
CREATE OR REPLACE FUNCTION public.jobs_inv_done(p_ids bigint[]) RETURNS bigint[]
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  RETURN coalesce((SELECT array_agg(job_id) FROM (
    SELECT i.job_id FROM invoices i WHERE i.job_id = ANY(p_ids) AND i.status <> 'void'
    GROUP BY i.job_id
    HAVING bool_or(i.status <> 'draft' AND (i.bill_to_partner_id IS NOT NULL OR i.paid_at_store OR coalesce(i.balance_due, 0) <= 0.004))) x), '{}');
END $function$;
REVOKE EXECUTE ON FUNCTION public.jobs_inv_done(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jobs_inv_done(bigint[]) TO authenticated;

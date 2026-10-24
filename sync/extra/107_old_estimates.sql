-- =====================================================================
-- Improvement 7: the Old estimates page: estimates still open (sent or draft) after 30+ days, oldest first.
-- Tick the dead ones and mark them "Not sold: no answer" in one go, or make a follow-up task for ones worth a call.
-- Owners and sales. Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public._can_old_estimates() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(public.current_staff_role() IN ('owner', 'sales'), false)
$$;

CREATE OR REPLACE FUNCTION public.old_estimates(p_days integer DEFAULT 30, p_limit integer DEFAULT 500)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '30s' AS $$
DECLARE v jsonb; lim int := least(greatest(coalesce(p_limit, 500), 1), 2000);
BEGIN
  IF NOT public._can_old_estimates() THEN RETURN NULL; END IF;
  WITH o AS (
    SELECT e.id, e.estimate_number, e.status, e.customer_id, e.sold_by_employee_id, e.created_at, e.sent_at, e.job_id,
           current_date - coalesce(e.sent_at, e.created_at)::date AS days
    FROM estimates e
    WHERE e.status IN ('sent', 'draft') AND e.cancelled_at IS NULL),
  pick AS (SELECT * FROM o WHERE days >= coalesce(p_days, 30) ORDER BY days DESC, id LIMIT lim),
  tot AS (SELECT op.estimate_id, max(s.t) AS best FROM estimate_options op
            JOIN LATERAL (SELECT coalesce(sum(l.line_total), 0) AS t FROM estimate_lines l WHERE l.estimate_option_id = op.id) s ON true
          WHERE op.estimate_id IN (SELECT id FROM pick) GROUP BY op.estimate_id)
  SELECT jsonb_build_object(
    'counts', (SELECT jsonb_build_object('30', count(*) FILTER (WHERE days BETWEEN 30 AND 89), '90', count(*) FILTER (WHERE days BETWEEN 90 AND 179),
                                         '180', count(*) FILTER (WHERE days BETWEEN 180 AND 364), '365', count(*) FILTER (WHERE days >= 365)) FROM o),
    'n', (SELECT count(*) FROM o WHERE days >= coalesce(p_days, 30)),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', p.id, 'number', p.estimate_number, 'status', p.status, 'days', p.days, 'date', coalesce(p.sent_at, p.created_at),
        'customer_id', p.customer_id, 'customer', c.display_name, 'total', t.best,
        'seller', nullif(concat_ws(' ', em.first_name, em.last_name), ''), 'job', j.job_number, 'job_type', jt.name,
        'sent', (SELECT max(d.sent_at) FROM doc_sends d WHERE d.kind = 'estimate' AND d.ref_id = p.id AND d.status = 'sent' AND NOT d.test),
        'tasks', (SELECT count(*) FROM follow_ups f WHERE f.customer_id = p.customer_id AND f.done_at IS NULL AND f.completed_at IS NULL))
      ORDER BY p.days DESC, p.id)
      FROM pick p LEFT JOIN customers c ON c.id = p.customer_id LEFT JOIN tot t ON t.estimate_id = p.id
      LEFT JOIN employees em ON em.id = p.sold_by_employee_id LEFT JOIN jobs j ON j.id = p.job_id LEFT JOIN job_types jt ON jt.id = j.job_type_id), '[]'))
  INTO v;
  RETURN v;
END $$;

-- mark many as "Not sold: no answer" (only ones still open and at least 30 days old)
CREATE OR REPLACE FUNCTION public.old_estimates_close(p_ids bigint[])
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n int;
BEGIN
  IF NOT public._can_old_estimates() THEN RAISE EXCEPTION 'Only owners and sales can do this'; END IF;
  IF coalesce(cardinality(p_ids), 0) > 2000 THEN RAISE EXCEPTION 'Too many at once (2000 at most)'; END IF;
  WITH u AS (
    UPDATE estimates e SET status = 'lost', lost_reason = 'no_response',
           lost_note = 'No answer after ' || (current_date - coalesce(e.sent_at, e.created_at)::date) || ' days (closed from Old estimates)', updated_at = now()
    WHERE e.id = ANY (p_ids) AND e.status IN ('sent', 'draft') AND e.cancelled_at IS NULL
      AND current_date - coalesce(e.sent_at, e.created_at)::date >= 30   -- never a new one
    RETURNING e.id),
  a AS (INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
        SELECT 'estimates', u.id, 'update', public.current_app_user_id(), jsonb_build_object('status', 'lost', 'reason', 'no_response', 'from', 'old_estimates') FROM u RETURNING 1)
  SELECT count(*) INTO n FROM a;
  RETURN n;
END $$;

REVOKE EXECUTE ON FUNCTION public._can_old_estimates(), public.old_estimates(integer, integer), public.old_estimates_close(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._can_old_estimates(), public.old_estimates(integer, integer), public.old_estimates_close(bigint[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

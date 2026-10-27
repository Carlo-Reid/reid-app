-- temporary: shows where Carlo view's installed / paid lookup spends its time (owners only). Removed again after the check.
DROP FUNCTION IF EXISTS public._diag_cv_plan();
CREATE OR REPLACE FUNCTION public._diag_cv_plan(p_which int DEFAULT 2)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
DECLARE r record; out text := '';
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'owners only'; END IF;
  -- the same steps written out, so the plan shows each one
  IF p_which = 2 THEN FOR r IN EXECUTE $q$EXPLAIN (ANALYZE, TIMING ON, COSTS OFF)
  WITH s AS MATERIALIZED (SELECT * FROM public._sales_hist_rows(NULL) r),
  ij AS MATERIALIZED (SELECT j.id, j.customer_id, j.sold_estimate_id, j.from_estimate_id FROM jobs j JOIN job_types t ON t.id = j.job_type_id
                      WHERE t.job_class = 'install' AND j.status <> 'cancelled'),
  l1 AS (SELECT s.est_id, ij.id AS jid, 1 AS pri FROM s JOIN ij ON ij.sold_estimate_id = s.est_id
         UNION ALL SELECT s.est_id, ij.id, 1 FROM s JOIN ij ON ij.from_estimate_id = s.est_id
         UNION ALL SELECT s.est_id, cs.job_id, 2 FROM s JOIN public._comm_sale_jobs() cs ON cs.est_id = s.est_id),
  rest AS (SELECT s.est_id, s.customer_id, s.amount FROM s WHERE NOT EXISTS (SELECT 1 FROM l1 WHERE l1.est_id = s.est_id)),
  un AS MATERIALIZED (SELECT ij.id, ij.customer_id FROM ij WHERE ij.sold_estimate_id IS NULL AND ij.from_estimate_id IS NULL
                        AND ij.customer_id IN (SELECT rest.customer_id FROM rest)),
  inv AS (SELECT i.job_id, sum(i.subtotal) AS sub FROM invoices i WHERE i.job_id IN (SELECT un.id FROM un) AND i.status NOT IN ('void', 'draft') GROUP BY i.job_id),
  l3 AS (SELECT rest.est_id, un.id AS jid, 3 AS pri FROM rest JOIN un ON un.customer_id = rest.customer_id
         LEFT JOIN install_tracking it ON it.job_id = un.id LEFT JOIN inv ON inv.job_id = un.id
         WHERE abs(coalesce(it.sale_amount, inv.sub) - rest.amount) < 1),
  best AS (SELECT DISTINCT ON (x.est_id) x.est_id, x.jid FROM (SELECT * FROM l1 UNION ALL SELECT * FROM l3) x ORDER BY x.est_id, x.pri, x.jid),
  d AS (
    SELECT b.est_id, j.id AS jid, j.status IN ('completed', 'invoiced', 'closed') AS done,
           CASE WHEN j.status IN ('completed', 'invoiced', 'closed')
                THEN coalesce(j.completed_at::date, (SELECT max(v.completed_at) FROM visits v WHERE v.job_id = j.id)::date)
                ELSE (SELECT min(v.scheduled_date) FROM visits v WHERE v.job_id = j.id AND v.status <> 'cancelled') END AS day
    FROM best b JOIN jobs j ON j.id = b.jid)
  SELECT count(*), count(d.day), count(it.paid_at) FROM s LEFT JOIN d ON d.est_id = s.est_id LEFT JOIN install_tracking it ON it.job_id = d.jid$q$ LOOP
    out := out || r."QUERY PLAN" || E'\n'; END LOOP; END IF;
  IF p_which = 1 THEN FOR r IN EXECUTE 'EXPLAIN (ANALYZE, TIMING ON, COSTS OFF) SELECT count(*) FROM public._sales_hist_rows(NULL)' LOOP out := out || r."QUERY PLAN" || E'\n'; END LOOP; END IF;
  -- the set-up for the slow-statement limit
  out := out || 'statement_timeout=' || current_setting('statement_timeout');
  RETURN out;
END $function$;
REVOKE EXECUTE ON FUNCTION public._diag_cv_plan(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._diag_cv_plan(int) TO authenticated;
NOTIFY pgrst, 'reload schema';

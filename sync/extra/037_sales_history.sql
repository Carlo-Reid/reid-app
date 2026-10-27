-- Carlo view on the Sales page: every sale made (every sold proposal), by year, month and day.
-- A sale = a proposal marked sold (accepted), not cancelled, worth more than $0.
-- Sold day = the day it was sold (or, for old ServiceTitan ones with no sold time, the day the job was made), Ottawa time.
-- Whose: everyone (owners / sales bosses), or one sales person (the "Sales page of" picker), with the same rules as the Sales page.
DROP FUNCTION IF EXISTS public._sales_hist_rows(bigint) CASCADE;   -- (its columns grew: partner)
CREATE OR REPLACE FUNCTION public._sales_hist_rows(p_seller bigint DEFAULT NULL)
 RETURNS TABLE(est_id bigint, est_number text, job_id bigint, job_number text, job_type text, sold_on date, amount numeric,
               customer_id bigint, customer text, address text, sales_person text, partner text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH me AS (SELECT public.current_app_user_id() AS uid, public._sales_boss() AS boss),
  who AS (SELECT CASE WHEN p_seller IS NULL AND me.boss THEN NULL ELSE coalesce(p_seller, me.uid) END AS seller FROM me),
  ok AS (SELECT public.current_staff_role() IS NOT NULL
                AND (me.boss OR who.seller = me.uid OR EXISTS (SELECT 1 FROM sales_viewers v WHERE v.viewer_user_id = me.uid AND v.seller_user_id = who.seller)) AS ok FROM me, who),
  tgt AS (SELECT u.id AS uid, u.employee_id AS emp FROM app_users u, who WHERE u.id = who.seller),
  s AS (
    SELECT e.id AS est_id, e.estimate_number AS est_number, j.id AS job_id, j.job_number, t.name AS job_type,
           (coalesce(e.accepted_at, j.created_at, e.created_at) AT TIME ZONE 'America/Toronto')::date AS sold_on,
           coalesce((SELECT sum(el.line_total) FROM estimate_lines el WHERE el.estimate_option_id = e.accepted_option_id), 0) AS amount,
           c.id AS customer_id, c.display_name AS customer, concat_ws(', ', l.street, l.city) AS address,
           coalesce((SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = j.sales_user_id),
                    public._emp_name(e.sold_by_employee_id)) AS sales_person,
           -- who it's for: the job's partner, or the partner the job type is named after ("Rona - Lead"), else Reid
           coalesce((SELECT btrim(pa.name) FROM partners pa WHERE pa.id = j.partner_id),
                    (SELECT btrim(pa.name) FROM partners pa WHERE length(split_part(btrim(t.name), ' ', 1)) > 2
                       AND lower(split_part(btrim(pa.name), ' ', 1)) = lower(split_part(btrim(t.name), ' ', 1)) ORDER BY pa.id LIMIT 1), 'Reid') AS partner
    FROM estimates e JOIN jobs j ON j.id = e.job_id LEFT JOIN job_types t ON t.id = j.job_type_id
    LEFT JOIN customers c ON c.id = coalesce(e.customer_id, j.customer_id)
    LEFT JOIN locations l ON l.id = coalesce(e.location_id, j.location_id)
    WHERE e.status = 'accepted' AND e.cancelled_at IS NULL AND j.sales_cancelled_at IS NULL AND (SELECT ok FROM ok)
      AND ((SELECT seller FROM who) IS NULL
           OR EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = j.sales_user_id OR (j.sales_user_id IS NULL AND tgt.emp = e.sold_by_employee_id))))
  SELECT * FROM s WHERE s.amount > 0
$function$;
REVOKE EXECUTE ON FUNCTION public._sales_hist_rows(bigint) FROM PUBLIC, anon, authenticated;

-- Totals for every day and sales person that had a sale: [{d, sp, n, amt}]. The page adds them up into months, years and people.
CREATE OR REPLACE FUNCTION public.sales_history_days(p_seller bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  SELECT coalesce(jsonb_agg(jsonb_build_object('d', d, 'sp', sp, 'pt', pt, 'n', n, 'amt', amt) ORDER BY d), '[]'::jsonb)
  FROM (SELECT sold_on AS d, coalesce(sales_person, '') AS sp, partner AS pt, count(*) AS n, sum(amount) AS amt FROM public._sales_hist_rows(p_seller) GROUP BY 1, 2, 3) x
$function$;
REVOKE EXECUTE ON FUNCTION public.sales_history_days(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_history_days(bigint) TO authenticated;

-- The sales themselves for a day, month or year (from - to, both included)
CREATE OR REPLACE FUNCTION public.sales_history(p_seller bigint DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.sold_on DESC, r.amount DESC), '[]'::jsonb)
  FROM public._sales_hist_rows(p_seller) r
  WHERE (p_from IS NULL OR r.sold_on >= p_from) AND (p_to IS NULL OR r.sold_on <= p_to)
$function$;
REVOKE EXECUTE ON FUNCTION public.sales_history(bigint, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_history(bigint, date, date) TO authenticated;
NOTIFY pgrst, 'reload schema';

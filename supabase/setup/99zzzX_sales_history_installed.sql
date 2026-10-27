-- 99zzzX: Carlo view by sold day or installed day. Also runs every night from sync/extra/038_sales_history_installed.sql. Safe to run more than once.
-- Carlo view: see sales by the day they were sold, the day they were installed, or the day their commission was paid.
-- Each sale's install = the install job made from its proposal; else the same call when it was sold and done on one call;
-- else (old ServiceTitan installs with no link) an install for the same customer with the same sale amount.
-- Installed day = the same day the Installs page uses: the day it was done, or (not done yet) its first booked day.
DROP FUNCTION IF EXISTS public._sales_hist_inst(bigint);   -- (replaced by the one below, which can look at sold days only)
DROP FUNCTION IF EXISTS public._sales_hist_inst(bigint, date, date);
CREATE OR REPLACE FUNCTION public._sales_hist_inst(p_seller bigint DEFAULT NULL, p_sold_from date DEFAULT NULL, p_sold_to date DEFAULT NULL)
 RETURNS TABLE(est_id bigint, est_number text, job_id bigint, job_number text, job_type text, sold_on date, amount numeric,
               customer_id bigint, customer text, address text, sales_person text, partner text, installed_on date, inst_job_id bigint, inst_done boolean, paid_on date, paid_amount numeric)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH s AS MATERIALIZED (SELECT * FROM public._sales_hist_rows(p_seller) r
                          WHERE (p_sold_from IS NULL OR r.sold_on >= p_sold_from) AND (p_sold_to IS NULL OR r.sold_on <= p_sold_to)),
  ij AS MATERIALIZED (SELECT j.id, j.customer_id, j.sold_estimate_id, j.from_estimate_id FROM jobs j JOIN job_types t ON t.id = j.job_type_id
                      WHERE t.job_class = 'install' AND j.status <> 'cancelled'),
  l1 AS (SELECT s.est_id, ij.id AS jid, 1 AS pri FROM s JOIN ij ON ij.sold_estimate_id = s.est_id
         UNION ALL SELECT s.est_id, ij.id, 1 FROM s JOIN ij ON ij.from_estimate_id = s.est_id
         UNION ALL SELECT s.est_id, cs.job_id, 2 FROM s JOIN public._comm_sale_jobs() cs ON cs.est_id = s.est_id),
  -- old installs with no link: matched by customer and sale amount (only for sales not matched above)
  rest AS (SELECT s.est_id, s.customer_id, s.amount FROM s WHERE NOT EXISTS (SELECT 1 FROM l1 WHERE l1.est_id = s.est_id)),
  un AS MATERIALIZED (SELECT ij.id, ij.customer_id FROM ij WHERE ij.sold_estimate_id IS NULL AND ij.from_estimate_id IS NULL
                        AND ij.customer_id IN (SELECT rest.customer_id FROM rest)),
  inv AS MATERIALIZED (SELECT i.job_id, sum(i.subtotal) AS sub FROM invoices i WHERE i.job_id IN (SELECT un.id FROM un) AND i.status NOT IN ('void', 'draft') GROUP BY i.job_id),
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
  SELECT s.est_id, s.est_number, s.job_id, s.job_number, s.job_type, s.sold_on, s.amount, s.customer_id, s.customer, s.address, s.sales_person, s.partner,
         d.day, d.jid, d.done, (coalesce(it.paid_at, it.prepaid_at) AT TIME ZONE 'America/Toronto')::date,
         CASE WHEN it.paid_at IS NOT NULL THEN it.paid_amount ELSE it.prepaid_amount END
  FROM s LEFT JOIN d ON d.est_id = s.est_id LEFT JOIN install_tracking it ON it.job_id = d.jid
$function$;
REVOKE EXECUTE ON FUNCTION public._sales_hist_inst(bigint, date, date) FROM PUBLIC, anon, authenticated;

-- Totals for every day and sales person: by the sold day (p_by 'sold'), the installed day ('installed') or the day its commission was paid ('paid')
CREATE OR REPLACE FUNCTION public.sales_history_days_by(p_seller bigint DEFAULT NULL, p_by text DEFAULT 'sold')
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  SELECT CASE WHEN p_by IN ('installed', 'paid') THEN
    (SELECT coalesce(jsonb_agg(jsonb_build_object('d', d, 'sp', sp, 'pt', pt, 'n', n, 'amt', amt) ORDER BY d), '[]'::jsonb)
     FROM (SELECT CASE p_by WHEN 'installed' THEN installed_on ELSE paid_on END AS d, coalesce(sales_person, '') AS sp, partner AS pt, count(*) AS n,
                  CASE WHEN p_by = 'paid' THEN coalesce(sum(paid_amount), 0) ELSE sum(amount) END AS amt
           FROM public._sales_hist_inst(p_seller) GROUP BY 1, 2, 3) x WHERE d IS NOT NULL)
  ELSE public.sales_history_days(p_seller) END   -- by the sold day: the quick way (no installs to match)
$function$;
REVOKE EXECUTE ON FUNCTION public.sales_history_days_by(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_history_days_by(bigint, text) TO authenticated;

-- The sales themselves for a day, month or year (from - to, both included), with their installed day
CREATE OR REPLACE FUNCTION public.sales_history_by(p_seller bigint DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_by text DEFAULT 'sold')
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY CASE p_by WHEN 'installed' THEN r.installed_on WHEN 'paid' THEN r.paid_on ELSE r.sold_on END DESC, r.amount DESC), '[]'::jsonb)
  FROM public._sales_hist_inst(p_seller, CASE WHEN p_by IN ('installed', 'paid') THEN NULL ELSE p_from END, CASE WHEN p_by IN ('installed', 'paid') THEN NULL ELSE p_to END) r
  WHERE (CASE p_by WHEN 'installed' THEN r.installed_on WHEN 'paid' THEN r.paid_on ELSE r.sold_on END) IS NOT NULL
    AND (p_from IS NULL OR (CASE p_by WHEN 'installed' THEN r.installed_on WHEN 'paid' THEN r.paid_on ELSE r.sold_on END) >= p_from)
    AND (p_to IS NULL OR (CASE p_by WHEN 'installed' THEN r.installed_on WHEN 'paid' THEN r.paid_on ELSE r.sold_on END) <= p_to)
$function$;
REVOKE EXECUTE ON FUNCTION public.sales_history_by(bigint, date, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_history_by(bigint, date, date, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

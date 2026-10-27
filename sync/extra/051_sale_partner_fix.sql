-- Sales page, "For" column: an owner / sales boss can fix who a sale is for (Reid or a partner) when it was set wrong.
-- The fix is kept in sale_partner_fix so the nightly ServiceTitan sync can't put the old partner back.
-- Picking Reid stops the guess from the job type name ("Rona - Lead" -> Rona).
CREATE TABLE IF NOT EXISTS public.sale_partner_fix (
  job_id bigint PRIMARY KEY REFERENCES public.jobs(id) ON DELETE CASCADE,
  partner_id bigint REFERENCES public.partners(id),          -- NULL = Reid
  set_by_user_id bigint, set_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.sale_partner_fix ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS staff_read ON public.sale_partner_fix;
CREATE POLICY staff_read ON public.sale_partner_fix FOR SELECT TO authenticated USING ((SELECT public.current_staff_role()) IS NOT NULL);
REVOKE ALL ON public.sale_partner_fix FROM anon; GRANT SELECT ON public.sale_partner_fix TO authenticated;

-- keep the fixed partner on the job whatever the sync brings in
CREATE OR REPLACE FUNCTION public._job_partner_fix() RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE f record;
BEGIN
  SELECT * INTO f FROM sale_partner_fix WHERE job_id = NEW.id;
  IF FOUND THEN NEW.partner_id := f.partner_id; END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS jobs_partner_fix ON public.jobs;
CREATE TRIGGER jobs_partner_fix BEFORE INSERT OR UPDATE OF partner_id ON public.jobs FOR EACH ROW EXECUTE FUNCTION public._job_partner_fix();

CREATE OR REPLACE FUNCTION public.sales_set_partner(p_job bigint, p_partner bigint)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_name text;
BEGIN
  IF public.current_staff_role() IS NULL OR NOT (public.current_staff_role() = 'owner' OR public._sales_boss()) THEN
    RAISE EXCEPTION 'Only an owner or the sales boss can change who a sale is for'; END IF;
  IF p_partner IS NOT NULL THEN SELECT btrim(name) INTO v_name FROM partners WHERE id = p_partner;
    IF v_name IS NULL THEN RAISE EXCEPTION 'That partner was not found'; END IF; END IF;
  INSERT INTO sale_partner_fix (job_id, partner_id, set_by_user_id) VALUES (p_job, p_partner, public.current_app_user_id())
    ON CONFLICT (job_id) DO UPDATE SET partner_id = EXCLUDED.partner_id, set_by_user_id = EXCLUDED.set_by_user_id, set_at = now();
  UPDATE jobs SET partner_id = p_partner WHERE id = p_job;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('jobs', p_job, 'update', public.current_app_user_id(), jsonb_build_object('partner_id', p_partner, 'why', 'Sales page: who the sale is for'));
  RETURN coalesce(v_name, 'Reid');
END $$;
REVOKE EXECUTE ON FUNCTION public.sales_set_partner(bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_set_partner(bigint, bigint) TO authenticated;

-- Carlo view counts: the same as 037, plus the fix (a sale fixed to Reid is Reid, not guessed from the job type)
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
  -- each partner by the first word of its name (once, not for every sale)
  pw AS MATERIALIZED (SELECT DISTINCT ON (lower(split_part(btrim(name), ' ', 1))) lower(split_part(btrim(name), ' ', 1)) AS w, btrim(name) AS name
                      FROM partners ORDER BY lower(split_part(btrim(name), ' ', 1)), id),
  s AS (
    SELECT e.id AS est_id, e.estimate_number AS est_number, j.id AS job_id, j.job_number, t.name AS job_type,
           (coalesce(e.accepted_at, j.created_at, e.created_at) AT TIME ZONE 'America/Toronto')::date AS sold_on,
           coalesce((SELECT sum(el.line_total) FROM estimate_lines el WHERE el.estimate_option_id = e.accepted_option_id), 0) AS amount,
           c.id AS customer_id, c.display_name AS customer, concat_ws(', ', l.street, l.city) AS address,
           coalesce((SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = j.sales_user_id),
                    public._emp_name(e.sold_by_employee_id)) AS sales_person,
           -- who it's for: the job's partner, or the partner the job type is named after ("Rona - Lead"), else Reid
           coalesce(btrim(pj.name), CASE WHEN fx.job_id IS NOT NULL THEN 'Reid' END, pt.name, 'Reid') AS partner
    FROM estimates e JOIN jobs j ON j.id = e.job_id LEFT JOIN job_types t ON t.id = j.job_type_id
    LEFT JOIN partners pj ON pj.id = j.partner_id LEFT JOIN sale_partner_fix fx ON fx.job_id = j.id
    LEFT JOIN pw pt ON pt.w = lower(split_part(btrim(t.name), ' ', 1)) AND length(split_part(btrim(t.name), ' ', 1)) > 2
    LEFT JOIN customers c ON c.id = coalesce(e.customer_id, j.customer_id)
    LEFT JOIN locations l ON l.id = coalesce(e.location_id, j.location_id)
    WHERE e.status = 'accepted' AND e.cancelled_at IS NULL AND j.sales_cancelled_at IS NULL AND (SELECT ok FROM ok)
      AND ((SELECT seller FROM who) IS NULL
           OR EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = j.sales_user_id OR (j.sales_user_id IS NULL AND tgt.emp = e.sold_by_employee_id))))
  SELECT * FROM s WHERE s.amount > 0
$function$;
REVOKE EXECUTE ON FUNCTION public._sales_hist_rows(bigint) FROM PUBLIC, anon, authenticated;
NOTIFY pgrst, 'reload schema';

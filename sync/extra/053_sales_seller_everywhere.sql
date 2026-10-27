-- Sales page: changing the sales person on a sale changes it everywhere that sale shows:
--   the sales job (who it's for on the Sales page), the job's "sold by", its proposals' "sold by",
--   the install job(s) it turned into ("sold by", which the invoice and the Installs / Commissions pages use),
--   and the commission's sales person on those installs (not once the commission has been paid).
-- The nightly ServiceTitan update can't put the old one back (sale_seller_fix keeps the choice).
CREATE TABLE IF NOT EXISTS public.sale_seller_fix (
  kind text NOT NULL CHECK (kind IN ('job', 'estimate')), row_id bigint NOT NULL, employee_id bigint,
  set_by_user_id bigint, set_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (kind, row_id));
ALTER TABLE public.sale_seller_fix ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sale_seller_fix FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._seller_fix_job() RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE v bigint; f boolean;
BEGIN
  SELECT employee_id, true INTO v, f FROM sale_seller_fix WHERE kind = 'job' AND row_id = NEW.id;
  IF f THEN NEW.sold_by_employee_id := v; END IF; RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION public._seller_fix_est() RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE v bigint; f boolean;
BEGIN
  SELECT employee_id, true INTO v, f FROM sale_seller_fix WHERE kind = 'estimate' AND row_id = NEW.id;
  IF f THEN NEW.sold_by_employee_id := v; END IF; RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS jobs_seller_fix ON public.jobs;
CREATE TRIGGER jobs_seller_fix BEFORE UPDATE OF sold_by_employee_id ON public.jobs FOR EACH ROW EXECUTE FUNCTION public._seller_fix_job();
DROP TRIGGER IF EXISTS estimates_seller_fix ON public.estimates;
CREATE TRIGGER estimates_seller_fix BEFORE UPDATE OF sold_by_employee_id ON public.estimates FOR EACH ROW EXECUTE FUNCTION public._seller_fix_est();

-- p_job: the sales job (or the call the proposal was sold on); p_user: the sales person (NULL = take them off);
-- p_installs: install jobs the Sales page shows under this sale (also the ones not linked in ServiceTitan)
CREATE OR REPLACE FUNCTION public.sales_set_seller(p_job bigint, p_user bigint, p_installs bigint[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE emp bigint; ests bigint[]; jobs_ bigint[]; n_paid int := 0; n_comm int := 0;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  IF NOT public._sales_boss() AND p_user IS DISTINCT FROM public.current_app_user_id() THEN RAISE EXCEPTION 'You can only put sales jobs on your own page'; END IF;
  IF p_user IS NOT NULL AND NOT EXISTS (SELECT 1 FROM app_users WHERE id = p_user AND role = 'sales') THEN RAISE EXCEPTION 'That person is not a sales person'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jobs WHERE id = p_job) THEN RAISE EXCEPTION 'Job not found'; END IF;
  UPDATE jobs SET sales_user_id = p_user, updated_at = now() WHERE id = p_job;
  emp := (SELECT employee_id FROM app_users WHERE id = p_user);
  IF emp IS NOT NULL THEN
    ests := ARRAY(SELECT id FROM estimates WHERE job_id = p_job);
    jobs_ := ARRAY(SELECT DISTINCT x FROM (
        SELECT p_job AS x
        UNION SELECT ij.id FROM jobs ij WHERE ij.sold_estimate_id = ANY (ests) OR ij.from_estimate_id = ANY (ests)
        UNION SELECT unnest(coalesce(p_installs, '{}'::bigint[]))) z WHERE x IS NOT NULL);
    INSERT INTO sale_seller_fix (kind, row_id, employee_id, set_by_user_id)
      SELECT 'job', x, emp, public.current_app_user_id() FROM unnest(jobs_) x
      UNION ALL SELECT 'estimate', x, emp, public.current_app_user_id() FROM unnest(ests) x
    ON CONFLICT (kind, row_id) DO UPDATE SET employee_id = EXCLUDED.employee_id, set_by_user_id = EXCLUDED.set_by_user_id, set_at = now();
    UPDATE jobs SET sold_by_employee_id = emp, updated_at = now() WHERE id = ANY (jobs_);
    UPDATE estimates SET sold_by_employee_id = emp, updated_at = now() WHERE id = ANY (ests);
    -- the commission's sales person (only where one was set by hand and it isn't paid yet; otherwise it follows "sold by")
    SELECT count(*) FILTER (WHERE paid_at IS NOT NULL AND salesperson_id IS DISTINCT FROM emp) INTO n_paid FROM install_tracking WHERE job_id = ANY (jobs_);
    UPDATE install_tracking SET salesperson_id = emp WHERE job_id = ANY (jobs_) AND paid_at IS NULL AND salesperson_id IS DISTINCT FROM emp;
    GET DIAGNOSTICS n_comm = ROW_COUNT;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('jobs', p_job, 'update', public.current_app_user_id(),
          jsonb_build_object('sales_user_id', p_user, 'sold_by_employee_id', emp, 'jobs', to_jsonb(jobs_), 'estimates', to_jsonb(ests), 'why', 'Sales page: sales person changed everywhere'));
  RETURN jsonb_build_object('jobs', coalesce(cardinality(jobs_), 0), 'estimates', coalesce(cardinality(ests), 0), 'commissions', n_comm, 'paid_kept', n_paid);
END $$;
REVOKE EXECUTE ON FUNCTION public.sales_set_seller(bigint, bigint, bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_set_seller(bigint, bigint, bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

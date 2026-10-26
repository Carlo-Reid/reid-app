-- Commissions page: take a sales person off the rates table (all their rates, by type of work and usual).
-- A rate typed on one install stays. Safe to run more than once.
CREATE OR REPLACE FUNCTION public.comm_person_remove(p_emp bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT public._can_installs() THEN RAISE EXCEPTION 'You don''t have permission to set commission rates'; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values)
  SELECT 'commission_rates', p_emp, 'delete', public.current_app_user_id(),
         jsonb_build_object('usual', (SELECT pct FROM commission_rates WHERE employee_id = p_emp),
                            'by_type', (SELECT jsonb_object_agg(g.name, r.pct) FROM commission_group_rates r JOIN commission_groups g ON g.id = r.group_id WHERE r.employee_id = p_emp));
  DELETE FROM commission_group_rates WHERE employee_id = p_emp;
  DELETE FROM commission_rates WHERE employee_id = p_emp;
END $f$;
REVOKE EXECUTE ON FUNCTION public.comm_person_remove(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.comm_person_remove(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

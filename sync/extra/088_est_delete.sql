-- Delete a proposal (from the customer page). Not one that's sold, nor one from ServiceTitan (it would come back on the next sync).
-- Owners can delete any of these; a sales person only their own.
CREATE OR REPLACE FUNCTION public.est_delete(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE e estimates; v_role text := public.current_staff_role();
BEGIN
  IF v_role IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT * INTO e FROM estimates WHERE id = p_id; IF e.id IS NULL THEN RAISE EXCEPTION 'That proposal is already gone'; END IF;
  IF e.status = 'accepted' AND e.cancelled_at IS NULL THEN RAISE EXCEPTION 'This proposal is sold, so it can''t be deleted. Un-sell it first.'; END IF;
  IF e.st_id IS NOT NULL THEN RAISE EXCEPTION 'This proposal came from ServiceTitan, so it would come back. Cancel it instead.'; END IF;
  IF v_role <> 'owner' AND e.sold_by_employee_id IS DISTINCT FROM public._my_employee()
     AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.id = e.job_id AND (j.sales_user_id = public.current_app_user_id() OR j.booked_by_user_id = public.current_app_user_id())) THEN
    RAISE EXCEPTION 'You can only delete your own proposals'; END IF;
  BEGIN
    DELETE FROM install_holds WHERE estimate_id = p_id;
    UPDATE jobs SET sold_estimate_id = NULL WHERE sold_estimate_id = p_id;
    UPDATE jobs SET from_estimate_id = NULL WHERE from_estimate_id = p_id;
    DELETE FROM estimate_lines WHERE estimate_option_id IN (SELECT id FROM estimate_options WHERE estimate_id = p_id);
    DELETE FROM estimate_options WHERE estimate_id = p_id;
    DELETE FROM estimates WHERE id = p_id;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'This proposal is linked to something else (an invoice or a sent copy), so it can''t be deleted. Cancel it instead.';
  END;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('estimates', p_id, 'delete', public.current_app_user_id(), jsonb_build_object('number', e.estimate_number, 'customer', e.customer_id));
END $function$;
REVOKE EXECUTE ON FUNCTION public.est_delete(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_delete(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

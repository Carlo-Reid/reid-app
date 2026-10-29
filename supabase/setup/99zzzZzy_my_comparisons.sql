-- The side-by-side comparisons a person saved for customers (the training view's My comparisons page), newest first.
-- Owners see everyone's. Also: a sales person can only delete their own comparisons.
CREATE OR REPLACE FUNCTION public.my_comparisons() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'items', c.items, 'estimate_id', c.estimate_id,
             'estimate_number', e.estimate_number, 'estimate_status', e.status, 'estimate_cancelled', e.cancelled_at IS NOT NULL,
             'customer_id', c.customer_id, 'customer', cu.display_name, 'at', c.created_at, 'mine', c.created_by = public.current_app_user_id(),
             'by', (SELECT public._emp_name(u.employee_id) FROM app_users u WHERE u.id = c.created_by)) ORDER BY c.created_at DESC)
    FROM customer_comparisons c JOIN customers cu ON cu.id = c.customer_id LEFT JOIN estimates e ON e.id = c.estimate_id
    WHERE (c.created_by = public.current_app_user_id() OR public.current_staff_role() = 'owner') AND NOT public._practice_hidden(cu.id)), '[]'::jsonb) END
$function$;
REVOKE EXECUTE ON FUNCTION public.my_comparisons() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_comparisons() TO authenticated;

CREATE OR REPLACE FUNCTION public.cmp_delete(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_by bigint;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT created_by INTO v_by FROM customer_comparisons WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That comparison is already gone'; END IF;
  IF public.current_staff_role() = 'sales' AND v_by IS DISTINCT FROM public.current_app_user_id() THEN RAISE EXCEPTION 'You can only delete comparisons you made'; END IF;
  DELETE FROM customer_comparisons WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('customer_comparisons', p_id, 'delete', public.current_app_user_id(), '{}'::jsonb);
END $function$;
NOTIFY pgrst, 'reload schema';

CREATE OR REPLACE FUNCTION public.cmp_list(p_customer bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'items', c.items, 'estimate_id', c.estimate_id,
             'estimate_number', e.estimate_number, 'estimate_status', e.status, 'estimate_cancelled', e.cancelled_at IS NOT NULL, 'at', c.created_at,
             'mine', c.created_by = public.current_app_user_id(),
             'by', (SELECT public._emp_name(u.employee_id) FROM app_users u WHERE u.id = c.created_by)) ORDER BY c.created_at DESC)
    FROM customer_comparisons c LEFT JOIN estimates e ON e.id = c.estimate_id WHERE c.customer_id = p_customer), '[]'::jsonb) END
$function$;
NOTIFY pgrst, 'reload schema';

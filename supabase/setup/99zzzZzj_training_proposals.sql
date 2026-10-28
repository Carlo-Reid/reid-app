-- The training view: a person can only change proposals they made (sold by them, or on a sales call that's theirs), whatever else they're allowed.
CREATE OR REPLACE FUNCTION public._est_can_change(p_id bigint) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM staff_training WHERE app_user_id = public.current_app_user_id())
    THEN EXISTS (SELECT 1 FROM estimates e LEFT JOIN jobs j ON j.id = e.job_id
                 WHERE e.id = p_id AND (e.sold_by_employee_id = public._my_employee() OR j.sales_user_id = public.current_app_user_id()))
    ELSE public.current_staff_role() IN ('owner', 'admin', 'office', 'accounting', 'manager')
      OR public.has_permission('invoices.create') OR public.has_permission('calls.dispatch')
      OR EXISTS (SELECT 1 FROM estimates e LEFT JOIN jobs j ON j.id = e.job_id
                 WHERE e.id = p_id AND (e.sold_by_employee_id = public._my_employee() OR j.sales_user_id = public.current_app_user_id())) END
$function$;
NOTIFY pgrst, 'reload schema';

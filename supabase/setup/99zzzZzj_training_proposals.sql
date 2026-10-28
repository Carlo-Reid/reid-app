-- The training view: a person can only change proposals they made (sold_by them, or a sales call that's theirs), whatever else they're allowed.
SELECT public._patch_fn('_est_can_change', $o$  SELECT public.current_staff_role() IN ('owner', 'admin', 'office', 'accounting', 'manager')$o$,
  $n$  SELECT CASE WHEN EXISTS (SELECT 1 FROM staff_training WHERE app_user_id = public.current_app_user_id())
              THEN EXISTS (SELECT 1 FROM estimates e LEFT JOIN jobs j ON j.id = e.job_id
                           WHERE e.id = p_id AND (e.sold_by_employee_id = public._my_employee() OR j.sales_user_id = public.current_app_user_id())) ELSE
         public.current_staff_role() IN ('owner', 'admin', 'office', 'accounting', 'manager')$n$);
SELECT public._patch_fn('_est_can_change', $o$WHERE e.id = p_id AND (e.sold_by_employee_id = public._my_employee() OR j.sales_user_id = public.current_app_user_id())))
$function$$o$, $n$WHERE e.id = p_id AND (e.sold_by_employee_id = public._my_employee() OR j.sales_user_id = public.current_app_user_id())) END)
$function$$n$);
NOTIFY pgrst, 'reload schema';

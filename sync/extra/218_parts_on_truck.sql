-- Dispatch ✨ Optimize: calls whose tech already has the parts for the job in his truck.
-- A tech has them when ServiceTitan shows stock received or transferred into his truck for that job,
-- or a PO for that job that he ordered has been received (fully or partly). Such a call is never offered in a swap.
-- Safe to run more than once.
CREATE OR REPLACE FUNCTION public.dispatch_parts_held(p_date date)
 RETURNS TABLE(visit_id bigint, employee_id bigint, what text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF public.current_staff_role() IS NULL OR p_date IS NULL THEN RETURN; END IF;
  RETURN QUERY
  SELECT v.id, va.employee_id, 'PO ' || min(po.po_number) || ' received'
  FROM visits v
  JOIN visit_assignments va ON va.visit_id = v.id
  JOIN purchase_orders po ON po.job_id = v.job_id AND po.ordered_by_employee_id = va.employee_id
                         AND po.status IN ('received', 'partially_received')
  WHERE v.scheduled_date = p_date
  GROUP BY v.id, va.employee_id;
  IF to_regclass('public.st_stock_history') IS NOT NULL THEN
    RETURN QUERY EXECUTE $q$
      SELECT v.id, va.employee_id, 'Parts in his truck (' || min(coalesce(h.item_name, h.item_code, 'item')) || CASE WHEN count(*) > 1 THEN ' and more' ELSE '' END || ')'
      FROM visits v
      JOIN visit_assignments va ON va.visit_id = v.id
      JOIN stock_locations sl ON sl.location_type = 'truck' AND sl.assigned_employee_id = va.employee_id AND sl.st_id IS NOT NULL
      JOIN st_stock_history h ON h.job_st_id = v.job_id AND h.to_st = sl.st_id AND h.kind IN ('receipts', 'transfers') AND h.active IS NOT FALSE
      WHERE v.scheduled_date = $1
      GROUP BY v.id, va.employee_id $q$ USING p_date;
  END IF;
END
$function$;
REVOKE EXECUTE ON FUNCTION public.dispatch_parts_held(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dispatch_parts_held(date) TO authenticated;
NOTIFY pgrst, 'reload schema';

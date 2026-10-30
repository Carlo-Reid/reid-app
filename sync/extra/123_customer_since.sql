-- When each customer started with us: the earliest of when they were added, their first job, their first visit and their first invoice
CREATE OR REPLACE FUNCTION public.customer_since(p_ids bigint[])
 RETURNS TABLE(customer_id bigint, since date) LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT c.id, least(c.created_at::date,
                     (SELECT min(j.created_at)::date FROM jobs j WHERE j.customer_id = c.id),
                     (SELECT min(v.scheduled_date) FROM visits v JOIN jobs j ON j.id = v.job_id WHERE j.customer_id = c.id),
                     (SELECT min(i.invoice_date) FROM invoices i WHERE i.customer_id = c.id))
  FROM customers c
  WHERE public.current_staff_role() IS NOT NULL AND c.id = ANY (p_ids[1:200])
$function$;
REVOKE EXECUTE ON FUNCTION public.customer_since(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_since(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

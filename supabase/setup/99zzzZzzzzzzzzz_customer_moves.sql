-- A customer who moved: their new file links to the old one. The new file shows the old file's notes (as their own tab)
-- and the years with us count from when they first became a customer at the old home, so they keep growing.
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS moved_from_customer_id bigint REFERENCES public.customers(id) ON DELETE SET NULL;
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS moved_on date;
CREATE INDEX IF NOT EXISTS customers_moved_from ON public.customers (moved_from_customer_id);

CREATE OR REPLACE FUNCTION public.customer_move_link(p_new bigint, p_old bigint)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT (public.has_permission('customers.edit') OR public.current_staff_role() = 'owner') THEN RAISE EXCEPTION 'You need "Edit customers" for this'; END IF;
  IF p_old IS NULL THEN
    UPDATE customers SET moved_from_customer_id = NULL, moved_on = NULL WHERE id = p_new;
  ELSE
    IF p_old = p_new THEN RAISE EXCEPTION 'Pick their old file, not this one'; END IF;
    IF NOT EXISTS (SELECT 1 FROM customers WHERE id = p_old) THEN RAISE EXCEPTION 'That customer isn''t there'; END IF;
    IF EXISTS (WITH RECURSIVE ch(id, n) AS (SELECT p_old, 0 UNION ALL SELECT c.moved_from_customer_id, ch.n + 1 FROM customers c JOIN ch ON c.id = ch.id WHERE c.moved_from_customer_id IS NOT NULL AND ch.n < 20)
               SELECT 1 FROM ch WHERE id = p_new) THEN RAISE EXCEPTION 'That file already came from this one'; END IF;
    UPDATE customers SET moved_from_customer_id = p_old, moved_on = coalesce(moved_on, current_date) WHERE id = p_new;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('customers', p_new, 'update', public.current_app_user_id(), jsonb_build_object('moved_from_customer_id', p_old));
END $function$;
REVOKE EXECUTE ON FUNCTION public.customer_move_link(bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_move_link(bigint, bigint) TO authenticated;

-- the start date now follows the old files back (a customer who moved twice keeps all their years)
CREATE OR REPLACE FUNCTION public.customer_since(p_ids bigint[])
 RETURNS TABLE(customer_id bigint, since date) LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  WITH RECURSIVE ch(root, id, n) AS (
    SELECT c.id, c.id, 0 FROM customers c WHERE public.current_staff_role() IS NOT NULL AND c.id = ANY (p_ids[1:200])
    UNION ALL
    SELECT ch.root, c.moved_from_customer_id, ch.n + 1 FROM customers c JOIN ch ON c.id = ch.id WHERE c.moved_from_customer_id IS NOT NULL AND ch.n < 10)
  SELECT ch.root, min(least(c.created_at::date,
                     (SELECT min(j.created_at)::date FROM jobs j WHERE j.customer_id = c.id),
                     (SELECT min(v.scheduled_date) FROM visits v JOIN jobs j ON j.id = v.job_id WHERE j.customer_id = c.id),
                     (SELECT min(i.invoice_date) FROM invoices i WHERE i.customer_id = c.id)))
  FROM ch JOIN customers c ON c.id = ch.id GROUP BY ch.root
$function$;
NOTIFY pgrst, 'reload schema';

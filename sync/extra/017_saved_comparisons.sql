-- Saved side-by-side comparisons on the customer's file (look at them again later; more than one per customer). Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.customer_comparisons (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES public.customers(id),
  estimate_id bigint REFERENCES public.estimates(id),
  title       text,
  items       jsonb NOT NULL DEFAULT '[]',
  created_by  bigint,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS customer_comparisons_customer_idx ON public.customer_comparisons (customer_id, created_at DESC);
ALTER TABLE public.customer_comparisons ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.cmp_save(p_customer bigint, p_estimate bigint, p_title text, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
DECLARE v bigint;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  IF NOT EXISTS (SELECT 1 FROM customers WHERE id = p_customer) THEN RAISE EXCEPTION 'That customer no longer exists'; END IF;
  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 OR jsonb_array_length(p_items) > 3 THEN RAISE EXCEPTION 'Pick 1 to 3 items to save'; END IF;
  INSERT INTO customer_comparisons (customer_id, estimate_id, title, items, created_by)
  VALUES (p_customer, p_estimate, left(nullif(btrim(coalesce(p_title, '')), ''), 200), p_items, public.current_app_user_id()) RETURNING id INTO v;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('customer_comparisons', v, 'insert', public.current_app_user_id(), jsonb_build_object('customer', p_customer));
  RETURN v;
END $f$;

CREATE OR REPLACE FUNCTION public.cmp_list(p_customer bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'items', c.items, 'estimate_id', c.estimate_id,
             'estimate_number', (SELECT estimate_number FROM estimates WHERE id = c.estimate_id), 'at', c.created_at,
             'by', (SELECT public._emp_name(u.employee_id) FROM app_users u WHERE u.id = c.created_by)) ORDER BY c.created_at DESC)
    FROM customer_comparisons c WHERE c.customer_id = p_customer), '[]'::jsonb) END
$f$;

CREATE OR REPLACE FUNCTION public.cmp_delete(p_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  DELETE FROM customer_comparisons WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('customer_comparisons', p_id, 'delete', public.current_app_user_id(), '{}'::jsonb);
END $f$;

REVOKE EXECUTE ON FUNCTION public.cmp_save(bigint, bigint, text, jsonb), public.cmp_list(bigint), public.cmp_delete(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cmp_save(bigint, bigint, text, jsonb), public.cmp_list(bigint), public.cmp_delete(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

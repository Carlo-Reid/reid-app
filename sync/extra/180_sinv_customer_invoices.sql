-- Supplier invoices: attach our customer invoice(s) to a supplier's invoice (the parts on Boone's invoice went on this customer's invoice).
-- Suggested first: the invoices on the PO's job.
CREATE TABLE IF NOT EXISTS public.supplier_invoice_customer_links (
  supplier_invoice_id bigint NOT NULL REFERENCES public.supplier_invoices(id) ON DELETE CASCADE, invoice_id bigint NOT NULL,
  linked_by bigint, linked_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (supplier_invoice_id, invoice_id));
CREATE INDEX IF NOT EXISTS supplier_invoice_customer_links_inv ON public.supplier_invoice_customer_links (invoice_id);
ALTER TABLE public.supplier_invoice_customer_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.supplier_invoice_customer_links FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._sinv_cinv(i invoices) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT jsonb_build_object('id', i.id, 'number', i.invoice_number, 'date', i.invoice_date, 'total', i.total, 'balance', i.balance_due, 'status', i.status,
    'who', coalesce((SELECT display_name FROM customers WHERE id = (SELECT customer_id FROM locations WHERE id = i.location_id)), (SELECT display_name FROM customers WHERE id = i.customer_id)),
    'street', (SELECT street FROM locations WHERE id = i.location_id), 'job', (SELECT job_number FROM jobs WHERE id = i.job_id)) $f$;

CREATE OR REPLACE FUNCTION public.sinv_cust_invoices(p_id bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE s supplier_invoices; v_job bigint;
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  SELECT * INTO s FROM supplier_invoices WHERE id = p_id; IF s.id IS NULL THEN RAISE EXCEPTION 'Not found'; END IF;
  SELECT job_id INTO v_job FROM purchase_orders WHERE id = public._sinv_po(s);
  RETURN jsonb_build_object(
    'linked', (SELECT coalesce(jsonb_agg(public._sinv_cinv(i) || jsonb_build_object('by', public._emp_name((SELECT employee_id FROM app_users WHERE id = k.linked_by)), 'at', k.linked_at) ORDER BY i.invoice_date, i.id), '[]')
               FROM supplier_invoice_customer_links k JOIN invoices i ON i.id = k.invoice_id WHERE k.supplier_invoice_id = p_id),
    'suggest', (SELECT coalesce(jsonb_agg(public._sinv_cinv(i) ORDER BY i.invoice_date DESC, i.id DESC), '[]') FROM invoices i
                WHERE v_job IS NOT NULL AND i.job_id = v_job AND coalesce(i.status, '') <> 'void'
                  AND NOT EXISTS (SELECT 1 FROM supplier_invoice_customer_links k WHERE k.supplier_invoice_id = p_id AND k.invoice_id = i.id)));
END $f$;

-- find our invoices by invoice #, job #, customer name or street
CREATE OR REPLACE FUNCTION public.sinv_cust_find(p_q text) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE q text := nullif(btrim(coalesce(p_q, '')), '');
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  IF q IS NULL OR length(q) < 2 THEN RETURN '[]'::jsonb; END IF;
  RETURN (SELECT coalesce(jsonb_agg(public._sinv_cinv(x) ORDER BY x.invoice_date DESC, x.id DESC), '[]') FROM (
    SELECT i.* FROM invoices i LEFT JOIN locations l ON l.id = i.location_id LEFT JOIN customers c ON c.id = coalesce(l.customer_id, i.customer_id) LEFT JOIN jobs j ON j.id = i.job_id
    WHERE coalesce(i.status, '') <> 'void' AND (i.invoice_number ILIKE q || '%' OR j.job_number ILIKE q || '%' OR c.display_name ILIKE '%' || q || '%' OR l.street ILIKE '%' || q || '%')
    ORDER BY (i.invoice_number = q) DESC, i.invoice_date DESC NULLS LAST, i.id DESC LIMIT 12) x);
END $f$;

CREATE OR REPLACE FUNCTION public.sinv_cust_link(p_sinv bigint, p_invoice bigint, p_on boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF p_on THEN
    IF NOT EXISTS (SELECT 1 FROM invoices WHERE id = p_invoice) THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
    INSERT INTO supplier_invoice_customer_links (supplier_invoice_id, invoice_id, linked_by) VALUES (p_sinv, p_invoice, public.current_app_user_id()) ON CONFLICT DO NOTHING;
  ELSE DELETE FROM supplier_invoice_customer_links WHERE supplier_invoice_id = p_sinv AND invoice_id = p_invoice; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoice_customer_links', p_sinv, CASE WHEN p_on THEN 'insert' ELSE 'delete' END, public.current_app_user_id(), jsonb_build_object('invoice', p_invoice));
END $f$;

REVOKE EXECUTE ON FUNCTION public._sinv_cinv(invoices), public.sinv_cust_invoices(bigint), public.sinv_cust_find(text), public.sinv_cust_link(bigint, bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sinv_cust_invoices(bigint), public.sinv_cust_find(text), public.sinv_cust_link(bigint, bigint, boolean) TO authenticated;
NOTIFY pgrst, 'reload schema';

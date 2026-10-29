-- Supplier invoices: "Make a payment" to a supplier (owners, and staff given "Pay suppliers"). Each payment keeps how much,
-- when, how it was paid and a reference. Every new way of paying is remembered, so it's in the drop-down next time.
INSERT INTO public.permissions (code, name, description, category, sort_order)
VALUES ('supplier.pay', 'Pay suppliers', 'Supplier invoices: record a payment to a supplier', 'Purchasing', 92)
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.supplier_pay_methods (
  name text PRIMARY KEY, created_by bigint, created_at timestamptz NOT NULL DEFAULT now(), uses int NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS public.supplier_payments (
  id bigserial PRIMARY KEY, supplier_id bigint NOT NULL, amount numeric(12,2) NOT NULL, paid_on date NOT NULL DEFAULT current_date,
  method text NOT NULL, reference text, note text, statement_id bigint, created_by bigint, created_at timestamptz NOT NULL DEFAULT now(),
  voided_at timestamptz, voided_by bigint);
CREATE INDEX IF NOT EXISTS supplier_payments_sup ON public.supplier_payments (supplier_id, paid_on DESC);
ALTER TABLE public.supplier_pay_methods ENABLE ROW LEVEL SECURITY; ALTER TABLE public.supplier_payments ENABLE ROW LEVEL SECURITY;
INSERT INTO public.supplier_pay_methods (name) VALUES ('Cheque'), ('EFT'), ('Credit card'), ('E-transfer') ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public._sup_pay_ok() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(public.current_staff_role() = 'owner', false) OR public.has_permission('supplier.pay') $$;

CREATE OR REPLACE FUNCTION public.supplier_pay_methods_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN NOT public._sup_pay_ok() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(name ORDER BY uses DESC, name) FROM supplier_pay_methods), '[]'::jsonb) END $$;

CREATE OR REPLACE FUNCTION public.supplier_payment_add(p jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_id bigint; v_m text := btrim(coalesce(p ->> 'method', '')); v_amt numeric := (p ->> 'amount')::numeric; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT public._sup_pay_ok() THEN RAISE EXCEPTION 'You don''t have permission to pay suppliers'; END IF;
  IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = (p ->> 'supplier_id')::bigint) THEN RAISE EXCEPTION 'Pick the supplier'; END IF;
  IF v_amt IS NULL OR v_amt = 0 THEN RAISE EXCEPTION 'Put in how much was paid'; END IF;
  IF v_m = '' THEN RAISE EXCEPTION 'Put in how it was paid'; END IF;
  -- the same way of paying, written another way ("cheque" / "Cheque"), is the same one
  SELECT name INTO v_m FROM supplier_pay_methods WHERE lower(name) = lower(v_m) UNION ALL SELECT v_m LIMIT 1;
  INSERT INTO supplier_pay_methods (name, created_by, uses) VALUES (v_m, v_me, 1) ON CONFLICT (name) DO UPDATE SET uses = supplier_pay_methods.uses + 1;
  INSERT INTO supplier_payments (supplier_id, amount, paid_on, method, reference, note, statement_id, created_by)
  VALUES ((p ->> 'supplier_id')::bigint, v_amt, coalesce((p ->> 'paid_on')::date, current_date), v_m, nullif(btrim(p ->> 'reference'), ''), nullif(btrim(p ->> 'note'), ''),
          (p ->> 'statement_id')::bigint, v_me) RETURNING id INTO v_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('supplier_payments', v_id, 'insert', v_me, p);
  RETURN v_id;
END $function$;

CREATE OR REPLACE FUNCTION public.supplier_payment_void(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._sup_pay_ok() THEN RAISE EXCEPTION 'You don''t have permission to pay suppliers'; END IF;
  UPDATE supplier_payments SET voided_at = now(), voided_by = public.current_app_user_id() WHERE id = p_id AND voided_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'That payment is already cancelled'; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('supplier_payments', p_id, 'update', public.current_app_user_id(), '{"voided": true}');
END $function$;

CREATE OR REPLACE FUNCTION public.supplier_payments_list(p_supplier bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN NOT public._sup_pay_ok() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'amount', x.amount, 'paid_on', x.paid_on, 'method', x.method,
      'reference', x.reference, 'note', x.note, 'voided', x.voided_at IS NOT NULL, 'at', x.created_at,
      'by', (SELECT public._emp_name(u.employee_id) FROM app_users u WHERE u.id = x.created_by)) ORDER BY x.paid_on DESC, x.id DESC)
    FROM (SELECT * FROM supplier_payments WHERE supplier_id = p_supplier ORDER BY paid_on DESC, id DESC LIMIT 50) x), '[]'::jsonb) END $$;
REVOKE EXECUTE ON FUNCTION public._sup_pay_ok(), public.supplier_pay_methods_list(), public.supplier_payment_add(jsonb), public.supplier_payment_void(bigint), public.supplier_payments_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._sup_pay_ok(), public.supplier_pay_methods_list(), public.supplier_payment_add(jsonb), public.supplier_payment_void(bigint), public.supplier_payments_list(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

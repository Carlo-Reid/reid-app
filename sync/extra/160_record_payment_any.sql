-- Receivables: record a payment on any invoice, ServiceTitan's too ("This invoice came from ServiceTitan, so change it there" is gone
-- for payments). The payment is kept in the app (a payment with no ServiceTitan id), and the nightly sync can't wipe it:
-- after ServiceTitan's figure is written, an invoice keeps at least what its payments add up to (never more than its total).
-- Runs after invoices_bank_paid (152), so a payment found in the bank and one recorded here aren't counted twice.
CREATE OR REPLACE FUNCTION public.inv_record_payment(p_invoice bigint, p_method text, p_amount numeric, p_reference text, p_on date DEFAULT CURRENT_DATE)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i invoices; v_pay bigint;
BEGIN
  SELECT * INTO i FROM invoices WHERE id = p_invoice; IF i.id IS NULL THEN RAISE EXCEPTION 'That invoice isn''t in the app'; END IF;
  IF i.st_id IS NULL THEN RETURN public.inv_take_payment(p_invoice, p_method, p_amount, p_reference, p_on); END IF;   -- the app's own invoices: as before
  IF NOT (public.has_permission('invoices.adjust') OR public.current_staff_role() IN ('owner', 'admin', 'accounting')) THEN RAISE EXCEPTION 'You need "Adjust invoices" to record payments'; END IF;
  IF i.status IN ('void', 'draft') THEN RAISE EXCEPTION 'This invoice is %', CASE WHEN i.status = 'void' THEN 'voided' ELSE 'not finished' END; END IF;
  IF p_method NOT IN ('card', 'cash', 'cheque', 'e_transfer', 'financing', 'eft') THEN RAISE EXCEPTION 'Pick how they paid'; END IF;
  IF coalesce(p_amount, 0) <= 0 THEN RAISE EXCEPTION 'Type the amount paid'; END IF;
  IF p_amount > i.balance_due + 0.005 THEN RAISE EXCEPTION 'That''s more than the % still owing', to_char(i.balance_due, 'FM$999,999,990.00'); END IF;
  IF coalesce(p_on, current_date) > current_date THEN RAISE EXCEPTION 'The day it was paid can''t be in the future'; END IF;
  INSERT INTO payments (payment_number, payer_type, customer_id, job_id, method, amount, received_on, reference, status, created_by_user_id)
  VALUES ('P' || nextval('app_payment_seq'), 'customer', i.customer_id, i.job_id, p_method, p_amount, coalesce(p_on, current_date),
          nullif(btrim(p_reference), ''), 'succeeded', public.current_app_user_id())
  RETURNING id INTO v_pay;
  INSERT INTO payment_applications (payment_id, invoice_id, amount, applied_by_user_id) VALUES (v_pay, i.id, p_amount, public.current_app_user_id());
  UPDATE invoices SET bank_paid = bank_paid WHERE id = i.id;   -- re-figure what's paid (keeps the payment even if nothing else did)
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('payments', v_pay, 'insert', public.current_app_user_id(), jsonb_build_object('invoice', i.invoice_number, 'amount', p_amount, 'method', p_method, 'paid_on', coalesce(p_on, current_date), 'reference', p_reference, 'servicetitan_invoice', true));
  RETURN v_pay;
END $function$;
REVOKE EXECUTE ON FUNCTION public.inv_record_payment(bigint, text, numeric, text, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inv_record_payment(bigint, text, numeric, text, date) TO authenticated;

-- a ServiceTitan invoice with payments recorded in the app keeps them: what's paid is at least what all its payments add up to
DO $do$
DECLARE gen boolean := (SELECT is_generated = 'ALWAYS' FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'invoices' AND column_name = 'balance_due');
BEGIN
  EXECUTE format($f$
  CREATE OR REPLACE FUNCTION public._inv_app_paid() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $b$
  DECLARE v numeric;
  BEGIN
    IF NEW.st_id IS NULL OR NEW.status IN ('void', 'draft') THEN RETURN NEW; END IF;
    IF NOT EXISTS (SELECT 1 FROM payment_applications pa JOIN payments p ON p.id = pa.payment_id WHERE pa.invoice_id = NEW.id AND p.st_id IS NULL) THEN RETURN NEW; END IF;
    SELECT coalesce(sum(pa.amount), 0) INTO v FROM payment_applications pa JOIN payments p ON p.id = pa.payment_id WHERE pa.invoice_id = NEW.id AND coalesce(p.status, 'succeeded') NOT IN ('failed', 'void', 'voided', 'refunded');
    IF v > coalesce(NEW.amount_paid, 0) + 0.004 THEN
      NEW.amount_paid := least(NEW.total, v);
      %s
      NEW.status := CASE WHEN NEW.amount_paid >= NEW.total - 0.004 THEN 'paid' ELSE 'partially_paid' END;
    END IF;
    RETURN NEW;
  END $b$;$f$, CASE WHEN gen THEN '' ELSE 'NEW.balance_due := greatest(0, NEW.total - NEW.amount_paid);' END);
END $do$;
DROP TRIGGER IF EXISTS invoices_zz_app_paid ON public.invoices;
CREATE TRIGGER invoices_zz_app_paid BEFORE INSERT OR UPDATE ON public.invoices FOR EACH ROW EXECUTE FUNCTION public._inv_app_paid();
NOTIFY pgrst, 'reload schema';

-- Invoices whose ServiceTitan balance is bigger than the invoice: a payment was taken off them (moved to another invoice or
-- refunded) without one ever being on them, e.g. 116782596 ($124.30, showing $273.32 owing). Count them as not paid,
-- the same as the sync now does, so they never show more owing than they're for. Recorded in the audit log.
DO $$
DECLARE r record; gen boolean;
BEGIN
  SELECT is_generated = 'ALWAYS' OR generation_expression IS NOT NULL INTO gen FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'invoices' AND column_name = 'balance_due';
  FOR r IN SELECT id, invoice_number, total, amount_paid, balance_due FROM invoices WHERE total >= 0 AND amount_paid < -0.004 AND status <> 'void' LOOP
    IF gen THEN UPDATE invoices SET amount_paid = 0, status = CASE WHEN total = 0 THEN status ELSE 'posted' END WHERE id = r.id;
    ELSE UPDATE invoices SET amount_paid = 0, balance_due = total, status = CASE WHEN total = 0 THEN status ELSE 'posted' END WHERE id = r.id; END IF;
    INSERT INTO audit_log (table_name, row_id, action, old_values, new_values)
    VALUES ('invoices', r.id, 'update', jsonb_build_object('amount_paid', r.amount_paid, 'balance_due', r.balance_due),
            jsonb_build_object('amount_paid', 0, 'balance_due', r.total, 'why', 'A payment was taken off this invoice in ServiceTitan without one being on it: it showed more owing than the invoice is for'));
  END LOOP;
END $$;

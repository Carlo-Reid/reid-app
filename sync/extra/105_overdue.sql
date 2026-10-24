-- =====================================================================
-- Improvement 5: the Overdue page: invoices still owing past their due date, oldest first, with when a reminder
-- was last sent, so you can work down the list and send each one a reminder (email / text, from the invoice).
-- Staff who can adjust invoices (same as Receivables). Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.overdue_invoices(p_days integer DEFAULT 90, p_who text DEFAULT 'customer', p_limit integer DEFAULT 300)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '30s' AS $$
DECLARE v jsonb; lim int := least(greatest(coalesce(p_limit, 300), 1), 1000);
BEGIN
  IF NOT coalesce(public.has_permission('invoices.adjust'), false) THEN RETURN NULL; END IF;
  WITH o AS (
    SELECT i.id, i.invoice_number, i.invoice_date, coalesce(i.due_date, i.invoice_date) AS due, i.balance_due, i.total, i.customer_id, i.bill_to_type, i.bill_to_partner_id,
           current_date - coalesce(i.due_date, i.invoice_date) AS days
    FROM invoices i
    WHERE i.status IN ('posted', 'partially_paid') AND coalesce(i.balance_due, 0) > 0.004
      AND i.bad_debt_at IS NULL AND i.not_owed_at IS NULL
      AND current_date - coalesce(i.due_date, i.invoice_date) >= 1),
  w AS (SELECT * FROM o WHERE CASE p_who WHEN 'partner' THEN bill_to_type = 'partner' WHEN 'customer' THEN coalesce(bill_to_type, 'customer') <> 'partner' ELSE true END),
  pick AS (SELECT * FROM w WHERE days >= coalesce(p_days, 90) ORDER BY days DESC, id LIMIT lim)
  SELECT jsonb_build_object(
    'buckets', (SELECT jsonb_build_object(
        '30', jsonb_build_object('n', count(*) FILTER (WHERE days BETWEEN 30 AND 59), 'amount', coalesce(sum(balance_due) FILTER (WHERE days BETWEEN 30 AND 59), 0)),
        '60', jsonb_build_object('n', count(*) FILTER (WHERE days BETWEEN 60 AND 89), 'amount', coalesce(sum(balance_due) FILTER (WHERE days BETWEEN 60 AND 89), 0)),
        '90', jsonb_build_object('n', count(*) FILTER (WHERE days BETWEEN 90 AND 179), 'amount', coalesce(sum(balance_due) FILTER (WHERE days BETWEEN 90 AND 179), 0)),
        '180', jsonb_build_object('n', count(*) FILTER (WHERE days >= 180), 'amount', coalesce(sum(balance_due) FILTER (WHERE days >= 180), 0))) FROM w),
    'n', (SELECT count(*) FROM w WHERE days >= coalesce(p_days, 90)),
    'amount', (SELECT coalesce(sum(balance_due), 0) FROM w WHERE days >= coalesce(p_days, 90)),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', p.id, 'number', p.invoice_number, 'date', p.invoice_date, 'due', p.due, 'days', p.days, 'balance', p.balance_due, 'total', p.total,
        'customer_id', p.customer_id, 'customer', c.display_name, 'partner', pt.name,
        'email', EXISTS (SELECT 1 FROM customer_contacts k WHERE k.customer_id = p.customer_id AND k.kind = 'email' AND k.value LIKE '%@%'),
        'reminded', (SELECT max(d.sent_at) FROM doc_sends d WHERE d.kind = 'invoice' AND d.ref_id = p.id AND d.status = 'sent' AND NOT d.test),
        'reminders', (SELECT count(*) FROM doc_sends d WHERE d.kind = 'invoice' AND d.ref_id = p.id AND d.status = 'sent' AND NOT d.test))
      ORDER BY p.days DESC, p.id) FROM pick p LEFT JOIN customers c ON c.id = p.customer_id LEFT JOIN partners pt ON pt.id = p.bill_to_partner_id), '[]'))
  INTO v;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION public.overdue_invoices(integer, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.overdue_invoices(integer, text, integer) TO authenticated;

CREATE INDEX IF NOT EXISTS doc_sends_ref_idx ON public.doc_sends (kind, ref_id);

NOTIFY pgrst, 'reload schema';

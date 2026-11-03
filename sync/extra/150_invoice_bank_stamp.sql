-- Receivables: which invoices have their money found in the bank (tied on the Bank page), for owners
CREATE OR REPLACE FUNCTION public.invoice_bank_stamp(p_ids bigint[]) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._bank_owner() THEN '{}'::jsonb ELSE
    coalesce((SELECT jsonb_object_agg(invoice_id, j) FROM (
      SELECT k.invoice_id, jsonb_build_object('date', max(b.txn_date), 'amount', sum(k.amount), 'n', count(*), 'account', max(b.account),
                                             'bank', (array_agg(b.description ORDER BY b.txn_date DESC))[1], 'how', max(k.how)) AS j
      FROM bank_invoice_links k JOIN bank_transactions b ON b.id = k.bank_id
      WHERE k.invoice_id = ANY (p_ids[1:2000]) GROUP BY k.invoice_id) x), '{}') END $f$;
REVOKE EXECUTE ON FUNCTION public.invoice_bank_stamp(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invoice_bank_stamp(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

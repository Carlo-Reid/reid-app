-- =====================================================================
-- Payments to suppliers found on the Bank page: each bank line paid to a supplier (by the payee's name on the bank line) is a payment
-- to that supplier, shown with their payments (Make a payment) and taken off what we owe them. Lennox ("LENNOX INDUSTRI BPY/FAC") and
-- Le Groupe Master ("LE GROUPE MASTER S.E.C." / "GROUPE MASTER") to start; more names can be added to supplier_bank_payees.
-- A bank line becomes a payment once (bank_id); new bank files are picked up with each sync and every 10 minutes. Safe to run more than once.
-- =====================================================================
ALTER TABLE public.supplier_payments ADD COLUMN IF NOT EXISTS bank_id bigint;
CREATE UNIQUE INDEX IF NOT EXISTS supplier_payments_bank ON public.supplier_payments (bank_id) WHERE bank_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS public.supplier_bank_payees (supplier_id bigint NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE, pattern text NOT NULL, PRIMARY KEY (supplier_id, pattern));
ALTER TABLE public.supplier_bank_payees ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.supplier_bank_payees FROM PUBLIC, anon, authenticated;
INSERT INTO supplier_bank_payees (supplier_id, pattern) SELECT id, 'LENNOX INDUSTRI%' FROM suppliers WHERE name ILIKE 'Lennox%' ORDER BY id LIMIT 1 ON CONFLICT DO NOTHING;
INSERT INTO supplier_bank_payees (supplier_id, pattern) SELECT id, '%GROUPE MASTER%' FROM suppliers WHERE name ILIKE 'Master%' ORDER BY id LIMIT 1 ON CONFLICT DO NOTHING;
INSERT INTO supplier_pay_methods (name) VALUES ('Bank payment') ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public._bank_supplier_payments() RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int;
BEGIN
  WITH hit AS (SELECT DISTINCT ON (b.id) b.id, p.supplier_id, b.txn_date, b.amount_out, btrim(coalesce(nullif(b.payee, ''), b.description)) AS who
               FROM bank_transactions b JOIN supplier_bank_payees p ON upper(coalesce(nullif(b.payee, ''), b.description)) LIKE upper(p.pattern) OR upper(b.description) LIKE upper(p.pattern)
               WHERE b.amount_out > 0 AND NOT EXISTS (SELECT 1 FROM supplier_payments s WHERE s.bank_id = b.id)
               ORDER BY b.id, p.supplier_id),
       ins AS (INSERT INTO supplier_payments (supplier_id, amount, paid_on, method, reference, note, bank_id)
               SELECT supplier_id, amount_out, txn_date, 'Bank payment', left(who, 120), 'From the bank (Bank page)', id FROM hit
               ON CONFLICT DO NOTHING RETURNING 1)
  SELECT count(*) INTO n FROM ins;
  RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public._bank_supplier_payments() FROM PUBLIC, anon, authenticated;

-- a supplier's payments (Make a payment): all of them, newest first, the ones from the bank marked
CREATE OR REPLACE FUNCTION public.supplier_payments_list(p_supplier bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN NOT public._sup_pay_ok() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'amount', x.amount, 'paid_on', x.paid_on, 'method', x.method,
      'reference', x.reference, 'note', x.note, 'voided', false, 'at', x.created_at, 'bank', x.bank_id IS NOT NULL,
      'by', CASE WHEN x.bank_id IS NOT NULL THEN 'the bank' ELSE (SELECT public._emp_name(u.employee_id) FROM app_users u WHERE u.id = x.created_by) END) ORDER BY x.paid_on DESC, x.id DESC)
    FROM (SELECT * FROM supplier_payments WHERE supplier_id = p_supplier AND voided_at IS NULL ORDER BY paid_on DESC, id DESC LIMIT 400) x), '[]'::jsonb) END $$;

CREATE OR REPLACE FUNCTION public._sinv_autolink(p_job bigint DEFAULT NULL) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int;
BEGIN
  IF p_job IS NULL THEN BEGIN PERFORM public._bank_supplier_payments(); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'bank payments: %', SQLERRM; END; END IF;
  IF p_job IS NULL THEN BEGIN PERFORM public._po_guess_jobs(); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'po guess: %', SQLERRM; END; END IF;
  WITH sp AS (SELECT s.id, coalesce(po.job_id, g.job_id) AS job_id FROM supplier_invoices s CROSS JOIN LATERAL (SELECT public._sinv_po(s) AS po_id) x
              JOIN purchase_orders po ON po.id = x.po_id LEFT JOIN po_job_guess g ON g.po_id = po.id
              WHERE coalesce(po.job_id, g.job_id) IS NOT NULL AND (p_job IS NULL OR coalesce(po.job_id, g.job_id) = p_job)),
       ins AS (INSERT INTO supplier_invoice_customer_links (supplier_invoice_id, invoice_id, linked_by, auto)
               SELECT sp.id, i.id, NULL, true FROM sp JOIN invoices i ON i.job_id = sp.job_id AND coalesce(i.status, '') <> 'void'
               WHERE NOT EXISTS (SELECT 1 FROM supplier_invoice_customer_unlinks u WHERE u.supplier_invoice_id = sp.id AND u.invoice_id = i.id)
               ON CONFLICT DO NOTHING RETURNING 1)
  SELECT count(*) INTO n FROM ins;
  IF p_job IS NULL THEN BEGIN PERFORM public._po_suggest_jobs(); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'po suggest: %', SQLERRM; END;
    BEGIN PERFORM public._sinv_suggest_jobs(); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'sinv suggest: %', SQLERRM; END; END IF;
  RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public._sinv_autolink(bigint) FROM PUBLIC, anon, authenticated;

DO $$ DECLARE n int; BEGIN n := public._bank_supplier_payments(); RAISE NOTICE 'bank supplier payments added: %', n; END $$;
NOTIFY pgrst, 'reload schema';

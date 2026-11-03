-- Bank as permissions an owner turns on per person (Staff page):
--   bank.view  = the Bank page with the same access as an owner (for the accountant)
--   bank.stamp = only see the "In the bank" stamp on Receivables, without opening the Bank page (for the bookkeeper)
INSERT INTO public.permissions (code, name, description, category, sort_order) VALUES
  ('bank.view', 'Bank page', 'Open the Bank page with the same access as an owner: transactions, ledger, totals, partner matching, loading bank files, attaching invoices and files', 'Pages', 91),
  ('bank.stamp', 'Bank stamp on Receivables', 'See the "In the bank" stamp on Receivables (paid and found in the bank), without opening the Bank page', 'Pages', 92)
ON CONFLICT (code) DO NOTHING;
CREATE OR REPLACE FUNCTION public._bank_owner() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(public.current_staff_role() = 'owner', false) OR public.has_permission('bank.view') $f$;
DO $do$
DECLARE src text := pg_get_functiondef('public.invoice_bank_stamp(bigint[])'::regprocedure);
BEGIN
  IF src NOT LIKE '%bank.stamp%' THEN
    EXECUTE replace(src, 'WHEN NOT public._bank_owner() THEN', 'WHEN NOT (public._bank_owner() OR public.has_permission(''bank.stamp'')) THEN'); END IF;
END $do$;
NOTIFY pgrst, 'reload schema';

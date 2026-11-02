-- Bank: a running total for the year on every regular payment (utilities, insurance, loans, leases, rent, fuel, taxes, cards,
-- suppliers, partners, people paid by e-Transfer…): any payee that shows up 4 or more times in that year.
-- Each line keeps its payee (the description without account and reference numbers) so the totals are quick.
ALTER TABLE public.bank_transactions ADD COLUMN IF NOT EXISTS payee text;
CREATE OR REPLACE FUNCTION public._bank_payee(d text) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT upper(btrim(regexp_replace(regexp_replace(coalesce(d, ''), '\d{3,}[-#\d]*|\$[\d,.]+', '', 'g'), '\s+', ' ', 'g'))) $f$;
UPDATE public.bank_transactions SET payee = public._bank_payee(description) WHERE payee IS DISTINCT FROM public._bank_payee(description);
CREATE OR REPLACE FUNCTION public._bank_payee_set() RETURNS trigger LANGUAGE plpgsql AS $f$ BEGIN NEW.payee := public._bank_payee(NEW.description); RETURN NEW; END $f$;
DROP TRIGGER IF EXISTS bank_payee_set ON public.bank_transactions;
CREATE TRIGGER bank_payee_set BEFORE INSERT OR UPDATE OF description ON public.bank_transactions FOR EACH ROW EXECUTE FUNCTION public._bank_payee_set();
CREATE INDEX IF NOT EXISTS bank_transactions_payee ON public.bank_transactions (account, payee, txn_date, id);

CREATE OR REPLACE FUNCTION public._bank_ytd(p_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  WITH x AS (SELECT * FROM bank_transactions WHERE id = p_id),
  y AS (SELECT b.* FROM bank_transactions b, x WHERE b.account = x.account AND b.payee = x.payee AND x.payee <> ''
          AND b.txn_date >= date_trunc('year', x.txn_date)::date AND b.txn_date < (date_trunc('year', x.txn_date) + interval '1 year')::date)
  SELECT jsonb_build_object('year', extract(year FROM x.txn_date)::int, 'payee', x.payee,
           'total', (SELECT sum(CASE WHEN x.amount_in > 0 THEN y.amount_in - y.amount_out ELSE y.amount_out - y.amount_in END) FROM y WHERE (y.txn_date, y.id) <= (x.txn_date, x.id)),
           'n', (SELECT count(*) FROM y WHERE (y.txn_date, y.id) <= (x.txn_date, x.id)),
           'year_total', (SELECT sum(CASE WHEN x.amount_in > 0 THEN y.amount_in - y.amount_out ELSE y.amount_out - y.amount_in END) FROM y),
           'year_n', (SELECT count(*) FROM y), 'in', x.amount_in > 0)
  FROM x
  WHERE public._bank_cat(x.description, x.code, x.amount_in) NOT IN ('Card & online payments in', 'Deposits', 'Cheques', 'Transfers', 'Other')
    AND (SELECT count(*) FROM y) >= 4 $f$;
REVOKE EXECUTE ON FUNCTION public._bank_ytd(bigint) FROM PUBLIC, anon;

DO $do$
DECLARE s1 text := pg_get_functiondef('public.bank_list(text, date, date, text, text, int, int, text)'::regprocedure);
BEGIN
  IF s1 LIKE '%CASE WHEN x.cat = ''Taxes & government'' THEN public._bank_ytd(x.id) END%' THEN
    EXECUTE replace(s1, 'CASE WHEN x.cat = ''Taxes & government'' THEN public._bank_ytd(x.id) END', 'public._bank_ytd(x.id)'); END IF;
END $do$;
NOTIFY pgrst, 'reload schema';

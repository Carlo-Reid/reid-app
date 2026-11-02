-- Bank: taxes and government payments (WSIB, CRA, EHT, GST…) carry a running total for their year, for the same payee
CREATE OR REPLACE FUNCTION public._bank_ytd(p_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT jsonb_build_object('year', extract(year FROM x.txn_date)::int, 'total', sum(b.amount_out - b.amount_in), 'n', count(*),
           'year_total', (SELECT sum(c.amount_out - c.amount_in) FROM bank_transactions c WHERE c.account = x.account AND date_trunc('year', c.txn_date) = date_trunc('year', x.txn_date)
                          AND btrim(regexp_replace(c.description, '\d{3,}[-#\d]*', '', 'g')) = btrim(regexp_replace(x.description, '\d{3,}[-#\d]*', '', 'g'))))
  FROM bank_transactions x JOIN bank_transactions b ON b.account = x.account AND b.txn_date >= date_trunc('year', x.txn_date)::date AND (b.txn_date, b.id) <= (x.txn_date, x.id)
       AND btrim(regexp_replace(b.description, '\d{3,}[-#\d]*', '', 'g')) = btrim(regexp_replace(x.description, '\d{3,}[-#\d]*', '', 'g'))
  WHERE x.id = p_id AND public._bank_cat(x.description, x.code, x.amount_in) = 'Taxes & government'
  GROUP BY x.id, x.txn_date, x.account, x.description $f$;
REVOKE EXECUTE ON FUNCTION public._bank_ytd(bigint) FROM PUBLIC, anon;
DO $do$
DECLARE s1 text := pg_get_functiondef('public.bank_list(text, date, date, text, text, int, int, text)'::regprocedure);
        s2 text := pg_get_functiondef('public.bank_ledger(text, text, date, date, boolean, int, int)'::regprocedure);
BEGIN
  IF s1 NOT LIKE '%_bank_ytd%' THEN
    s1 := replace(s1, $a$'transfer', public._bank_xfer(x.id),$a$, $a$'transfer', public._bank_xfer(x.id), 'ytd', CASE WHEN x.cat = 'Taxes & government' THEN public._bank_ytd(x.id) END,$a$);
    IF s1 NOT LIKE '%_bank_ytd%' THEN RAISE EXCEPTION 'bank_list: anchor not found'; END IF; EXECUTE s1; END IF;
  IF s2 NOT LIKE '%_bank_ytd%' THEN
    s2 := replace(s2, $a$'transfer', public._bank_xfer(x.id),$a$, $a$'transfer', public._bank_xfer(x.id), 'ytd', public._bank_ytd(x.id),$a$);
    IF s2 NOT LIKE '%_bank_ytd%' THEN RAISE EXCEPTION 'bank_ledger: anchor not found'; END IF; EXECUTE s2; END IF;
END $do$;
NOTIFY pgrst, 'reload schema';

-- Bank: a second account (Savings). Each transaction belongs to an account; the list, totals and loading are per account.
DROP FUNCTION IF EXISTS public.bank_import(jsonb, text);
DROP FUNCTION IF EXISTS public.bank_list(text, date, date, text, text, int, int);
DROP FUNCTION IF EXISTS public.bank_summary(int);
CREATE OR REPLACE FUNCTION public.bank_import(p_rows jsonb, p_file text DEFAULT NULL, p_account text DEFAULT 'main') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int := 0; t int := 0; x jsonb;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can load the bank'; END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    t := t + 1;
    INSERT INTO bank_transactions (account, txn_date, code, description, amount_out, amount_in, balance, file_name, loaded_by)
    VALUES (coalesce(nullif(p_account, ''), 'main'), (x ->> 'date')::date, coalesce(x ->> 'code', ''), btrim(coalesce(x ->> 'description', '')), coalesce((x ->> 'out')::numeric, 0), coalesce((x ->> 'in')::numeric, 0),
            (x ->> 'balance')::numeric, p_file, public.current_app_user_id())
    ON CONFLICT DO NOTHING;
    IF FOUND THEN n := n + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('read', t, 'added', n, 'already', t - n);
END $f$;

CREATE OR REPLACE FUNCTION public.bank_list(p_q text DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_cat text DEFAULT NULL, p_dir text DEFAULT NULL, p_limit int DEFAULT 300, p_offset int DEFAULT 0, p_account text DEFAULT 'main')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE q text := nullif(btrim(coalesce(p_q, '')), ''); amt numeric; r jsonb;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can see the bank'; END IF;
  IF q ~ '^\$?[\d,]+(\.\d{1,2})?$' THEN amt := replace(replace(q, '$', ''), ',', '')::numeric; END IF;
  WITH f AS (
    SELECT b.*, public._bank_cat(b.description, b.code, b.amount_in) AS cat FROM bank_transactions b
    WHERE b.account = coalesce(p_account, 'main') AND (p_from IS NULL OR b.txn_date >= p_from) AND (p_to IS NULL OR b.txn_date <= p_to)
      AND (p_dir IS NULL OR (p_dir = 'in' AND b.amount_in > 0) OR (p_dir = 'out' AND b.amount_out > 0))
      AND (q IS NULL OR (amt IS NOT NULL AND (b.amount_in = amt OR b.amount_out = amt)) OR b.description ILIKE '%' || q || '%' OR b.code ILIKE q OR b.note ILIKE '%' || q || '%')),
  g AS (SELECT * FROM f WHERE p_cat IS NULL OR cat = p_cat)
  SELECT jsonb_build_object(
    'count', (SELECT count(*) FROM g), 'in', (SELECT coalesce(sum(amount_in), 0) FROM g), 'out', (SELECT coalesce(sum(amount_out), 0) FROM g),
    'cats', (SELECT coalesce(jsonb_agg(jsonb_build_object('cat', cat, 'n', n, 'in', i, 'out', o) ORDER BY i + o DESC), '[]') FROM (SELECT cat, count(*) n, sum(amount_in) i, sum(amount_out) o FROM f GROUP BY cat) c),
    'first', (SELECT min(txn_date) FROM bank_transactions WHERE account = coalesce(p_account, 'main')), 'last', (SELECT max(txn_date) FROM bank_transactions WHERE account = coalesce(p_account, 'main')), 'all', (SELECT count(*) FROM bank_transactions WHERE account = coalesce(p_account, 'main')),
    'accounts', (SELECT coalesce(jsonb_object_agg(account, n), '{}') FROM (SELECT account, count(*) n FROM bank_transactions GROUP BY account) a),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'date', txn_date, 'code', code, 'description', description, 'out', amount_out, 'in', amount_in, 'balance', balance, 'cat', cat, 'note', note)
              ORDER BY txn_date DESC, id DESC), '[]') FROM (SELECT * FROM g ORDER BY txn_date DESC, id DESC LIMIT least(coalesce(p_limit, 300), 2000) OFFSET coalesce(p_offset, 0)) x)) INTO r;
  RETURN r;
END $f$;

CREATE OR REPLACE FUNCTION public.bank_summary(p_year int DEFAULT NULL, p_account text DEFAULT 'main') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE r jsonb;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can see the bank'; END IF;
  WITH f AS (SELECT b.*, public._bank_cat(b.description, b.code, b.amount_in) AS cat,
                    btrim(regexp_replace(regexp_replace(b.description, '\d{3,}[-#\d]*', '#', 'g'), '\s+', ' ', 'g')) AS who
             FROM bank_transactions b WHERE b.account = coalesce(p_account, 'main') AND (p_year IS NULL OR extract(year FROM b.txn_date) = p_year))
  SELECT jsonb_build_object(
    'years', (SELECT jsonb_agg(y ORDER BY y DESC) FROM (SELECT DISTINCT extract(year FROM txn_date)::int y FROM bank_transactions WHERE account = coalesce(p_account, 'main')) z),
    'in', (SELECT coalesce(sum(amount_in), 0) FROM f), 'out', (SELECT coalesce(sum(amount_out), 0) FROM f),
    'months', (SELECT coalesce(jsonb_agg(jsonb_build_object('m', m, 'in', i, 'out', o) ORDER BY m), '[]') FROM (SELECT to_char(txn_date, 'YYYY-MM') m, sum(amount_in) i, sum(amount_out) o FROM f GROUP BY 1) a),
    'cats', (SELECT coalesce(jsonb_agg(jsonb_build_object('cat', cat, 'n', n, 'in', i, 'out', o, 'months', ms) ORDER BY i + o DESC), '[]') FROM
               (SELECT cat, count(*) n, sum(amount_in) i, sum(amount_out) o,
                       (SELECT jsonb_object_agg(m, v) FROM (SELECT to_char(f2.txn_date, 'YYYY-MM') m, sum(f2.amount_in - f2.amount_out) v FROM f f2 WHERE f2.cat = f.cat GROUP BY 1) mm) ms
                FROM f GROUP BY cat) c),
    'top_in', (SELECT coalesce(jsonb_agg(jsonb_build_object('who', who, 'n', n, 'sum', s) ORDER BY s DESC), '[]') FROM (SELECT who, count(*) n, sum(amount_in) s FROM f WHERE amount_in > 0 GROUP BY who ORDER BY 3 DESC LIMIT 25) a),
    'top_out', (SELECT coalesce(jsonb_agg(jsonb_build_object('who', who, 'n', n, 'sum', s) ORDER BY s DESC), '[]') FROM (SELECT who, count(*) n, sum(amount_out) s FROM f WHERE amount_out > 0 GROUP BY who ORDER BY 3 DESC LIMIT 25) a)) INTO r;
  RETURN r;
END $f$;

REVOKE EXECUTE ON FUNCTION public.bank_import(jsonb, text, text), public.bank_list(text, date, date, text, text, int, int, text), public.bank_summary(int, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bank_import(jsonb, text, text), public.bank_list(text, date, date, text, text, int, int, text), public.bank_summary(int, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

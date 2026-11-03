-- (re-made on every sync, after 140-149 rebuild the older version)
-- Bank transactions: oldest first or newest first, monthly totals for what's shown, and up to 5,000 lines at once ("show every one")
DO $do$
DECLARE src text;
BEGIN
  -- the earlier files rebuild the 8-part version on every sync: rebuild this one from it each time, then drop it (two versions would clash)
  IF to_regprocedure('public.bank_list(text, date, date, text, text, integer, integer, text)') IS NULL THEN RETURN; END IF;
  DROP FUNCTION IF EXISTS public.bank_list(text, date, date, text, text, integer, integer, text, boolean);
  src := pg_get_functiondef('public.bank_list(text, date, date, text, text, integer, integer, text)'::regprocedure);
  src := replace(src, $a$p_account text DEFAULT 'main'::text)$a$, $a$p_account text DEFAULT 'main'::text, p_asc boolean DEFAULT false)$a$);
  src := replace(src, 'ORDER BY txn_date DESC, id DESC', 'ORDER BY CASE WHEN p_asc THEN txn_date END, CASE WHEN p_asc THEN id END, txn_date DESC, id DESC');
  src := replace(src, 'least(coalesce(p_limit, 300), 2000)', 'least(coalesce(p_limit, 300), 5000)');
  src := replace(src, $a$'count', (SELECT count(*) FROM g),$a$, $a$'count', (SELECT count(*) FROM g),
    'months', (SELECT coalesce(jsonb_agg(jsonb_build_object('m', m, 'n', n, 'in', i, 'out', o) ORDER BY m), '[]') FROM (SELECT to_char(txn_date, 'YYYY-MM') m, count(*) n, sum(amount_in) i, sum(amount_out) o FROM g GROUP BY 1) mm),$a$);
  IF src NOT LIKE '%p_asc boolean%' OR src NOT LIKE '%CASE WHEN p_asc THEN txn_date END%' OR src NOT LIKE '%''months''%' THEN RAISE EXCEPTION 'bank_list: anchors not found'; END IF;
  DROP FUNCTION public.bank_list(text, date, date, text, text, integer, integer, text);
  EXECUTE src;
  REVOKE EXECUTE ON FUNCTION public.bank_list(text, date, date, text, text, integer, integer, text, boolean) FROM PUBLIC, anon;
  GRANT EXECUTE ON FUNCTION public.bank_list(text, date, date, text, text, integer, integer, text, boolean) TO authenticated;
END $do$;
NOTIFY pgrst, 'reload schema';

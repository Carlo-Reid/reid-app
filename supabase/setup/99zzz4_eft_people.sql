-- =====================================================================
-- Security page: "People in the EFT files". Everyone in the emailed EFT lists, once each (the newest file they're in),
-- matched to the customer in the database the same way as Review (customer #, then phone, then exact name).
-- Owners only. Needs 99zz and 99zz11. Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.pap_file_people()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '60s' AS $$
DECLARE v jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RETURN NULL; END IF;
  WITH e AS (
    SELECT i.id AS inbox_id, i.mail_id, i.file_name, i.received_at, i.pap_list AS file_list,
           btrim(coalesce(x ->> 0, '')) AS num, btrim(coalesce(x ->> 1, '')) AS name, btrim(coalesce(x ->> 2, '')) AS phone
    FROM pap_inbox i, jsonb_array_elements(i.rows) x
    WHERE i.rows IS NOT NULL AND i.status <> 'ignored' AND jsonb_typeof(x) = 'array'),
  k AS (SELECT e.*, coalesce(nullif(lower(e.num), ''), lower(e.name) || '|' || right(regexp_replace(e.phone, '\D', '', 'g'), 10)) AS key FROM e
        WHERE e.num <> '' OR e.name <> '' OR e.phone <> ''),
  c AS (SELECT key, count(DISTINCT inbox_id) AS files FROM k GROUP BY key),
  r AS (SELECT DISTINCT ON (k.key) k.*, c.files, (row_number() OVER ())::int AS n
        FROM k JOIN c USING (key) ORDER BY k.key, k.received_at DESC NULLS LAST, k.inbox_id DESC),
  m AS (SELECT * FROM public.pap_match((SELECT coalesce(jsonb_agg(jsonb_build_object('i', r.n, 'num', r.num, 'name', r.name, 'phone', r.phone)), '[]') FROM r)))
  SELECT jsonb_build_object(
    'n', (SELECT count(*) FROM r),
    'found', (SELECT count(*) FROM m),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
       'num', r.num, 'name', r.name, 'phone', r.phone, 'file', r.file_name, 'received', r.received_at, 'mail_id', r.mail_id,
       'file_list', r.file_list, 'files', r.files,
       'customer_id', m.customer_id, 'customer_number', m.customer_number, 'customer_name', m.name, 'how', m.how, 'pap_list', m.pap_list,
       'address', (SELECT concat_ws(', ', l.street, l.city) FROM locations l WHERE l.customer_id = m.customer_id ORDER BY l.active DESC, l.id LIMIT 1))
       ORDER BY lower(coalesce(nullif(r.name, ''), m.name, r.num))), '[]'))
  INTO v
  FROM r LEFT JOIN m ON m.i = r.n;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION public.pap_file_people() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_file_people() TO authenticated;

NOTIFY pgrst, 'reload schema';

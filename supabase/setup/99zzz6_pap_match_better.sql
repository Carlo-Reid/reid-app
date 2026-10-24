-- =====================================================================
-- Security page: better matching of EFT / PAP files to customers (Review, uploads and People in the EFT files).
--   1. Customer #: as written, or without a "C" / "C#" in front ("C#758" -> 758). It only counts when the name in the
--      file looks like the customer (a word of it is in the customer's name), so a wrong number can't match the wrong person.
--   2. Address code: "616bo" = the customer whose address starts "616 Bo..." (only when one customer has it).
--   3. Phone.
--   4. Name: "First Last", "Last, First", and each person of "John & Linda Albert" (only when one customer has it).
-- People in the EFT files also shows each person's amount and the bank's response (Approved, NSF...).
-- Needs 99zz, 99zzz4, 99zzz5. Safe to run more than once.
-- =====================================================================
CREATE INDEX IF NOT EXISTS customers_number_idx ON public.customers (customer_number);

CREATE OR REPLACE FUNCTION public.pap_match(p_rows jsonb)
RETURNS TABLE (i int, customer_id bigint, customer_number text, name text, how text, pap_list text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '60s' AS $$
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  RETURN QUERY
  WITH r0 AS MATERIALIZED (
    SELECT x.i, nullif(regexp_replace(btrim(coalesce(x.num, '')), '\.0+$', ''), '') AS num,
           nullif(btrim(regexp_replace(lower(replace(coalesce(x.name, ''), '&amp;', '&')), '\s+', ' ', 'g')), '') AS nm,
           nullif(right(regexp_replace(coalesce(x.phone, ''), '\D', '', 'g'), 10), '') AS ph
    FROM jsonb_to_recordset(p_rows) AS x(i int, num text, name text, phone text)),
  r AS MATERIALIZED (
    SELECT r0.*,
           nullif(regexp_replace(r0.num, '^[Cc]\s*#\s*|^[Cc](?=[0-9])', ''), '') AS num2,
           CASE WHEN r0.num ~ '^[0-9]{1,6}\s*[A-Za-z]{2,}$' THEN substring(r0.num from '^[0-9]+') END AS a_no,
           CASE WHEN r0.num ~ '^[0-9]{1,6}\s*[A-Za-z]{2,}$' THEN lower(substring(r0.num from '[A-Za-z]+$')) END AS a_st,
           (SELECT array_agg(w) FROM regexp_split_to_table(coalesce(r0.nm, ''), '[^a-z0-9]+') w
             WHERE length(w) >= 3 AND w NOT IN ('and', 'the', 'inc', 'ltd', 'canada', 'ont', 'ontario', 'corp', 'dr')) AS words
    FROM r0),
  -- name versions: whole name, "first last" and "last, first" for each first name in "John & Linda Albert"
  nv AS MATERIALIZED (
    SELECT DISTINCT r.i, v FROM r,
      LATERAL (SELECT substring(r.nm from '(\S+)$') AS last, regexp_replace(r.nm, '\s*\S+$', '') AS rest) p,
      LATERAL (SELECT r.nm AS v
               UNION ALL SELECT btrim(f) || ' ' || p.last FROM regexp_split_to_table(p.rest, '\s*&\s*|\s+and\s+') f WHERE btrim(f) <> '' AND p.rest <> ''
               UNION ALL SELECT p.last || ', ' || btrim(f) FROM regexp_split_to_table(p.rest, '\s*&\s*|\s+and\s+') f WHERE btrim(f) <> '' AND p.rest <> '') vv
    WHERE r.nm IS NOT NULL),
  byname AS MATERIALIZED (SELECT nv.i, min(c.id) AS id, count(DISTINCT c.id) AS n FROM nv
             JOIN customers c ON lower(btrim(c.display_name)) = nv.v AND c.merged_into_id IS NULL GROUP BY nv.i),
  byphone AS MATERIALIZED (SELECT right(regexp_replace(k.value, '\D', '', 'g'), 10) AS ph, min(k.customer_id) AS id, count(DISTINCT k.customer_id) AS n FROM customer_contacts k
              WHERE k.kind IN ('phone', 'mobile') AND right(regexp_replace(k.value, '\D', '', 'g'), 10) IN (SELECT r.ph FROM r WHERE length(r.ph) = 10) GROUP BY 1),
  byaddr AS MATERIALIZED (SELECT r.i, min(coalesce(c.merged_into_id, c.id)) AS id, count(DISTINCT coalesce(c.merged_into_id, c.id)) AS n
              FROM r JOIN locations l ON r.a_no IS NOT NULL AND split_part(btrim(l.street), ' ', 1) = r.a_no
                AND lower(regexp_replace(btrim(l.street), '^[0-9]+\s*', '')) LIKE r.a_st || '%'
              JOIN customers c ON c.id = l.customer_id
              GROUP BY r.i),
  bynum AS MATERIALIZED (
    SELECT r.i, (SELECT c.id FROM customers c
                 WHERE (c.customer_number IN (r.num, r.num2) OR (r.num2 ~ '^[0-9]{1,15}$' AND c.st_id = CASE WHEN r.num2 ~ '^[0-9]{1,15}$' THEN r.num2::bigint END))
                   AND (r.words IS NULL OR EXISTS (SELECT 1 FROM unnest(r.words) w WHERE position(w IN lower(c.display_name)) > 0))
                 ORDER BY (c.customer_number = r.num) DESC, c.merged_into_id IS NULL DESC, c.id LIMIT 1) AS id
    FROM r WHERE r.num IS NOT NULL),
  m AS MATERIALIZED (
    SELECT r.i, bn.id AS by_num, CASE WHEN a.n = 1 THEN a.id END AS by_addr, CASE WHEN p.n = 1 THEN p.id END AS by_phone, CASE WHEN b.n = 1 THEN b.id END AS by_name
    FROM r
    LEFT JOIN bynum bn ON bn.i = r.i
    LEFT JOIN byaddr a ON a.i = r.i
    LEFT JOIN byphone p ON p.ph = r.ph
    LEFT JOIN byname b ON b.i = r.i)
  SELECT m.i, c.id, c.customer_number, c.display_name,
         CASE WHEN m.by_num IS NOT NULL THEN 'number' WHEN m.by_addr IS NOT NULL THEN 'address' WHEN m.by_phone IS NOT NULL THEN 'phone' ELSE 'name' END,
         c.pap_list
  FROM m
  JOIN customers c0 ON c0.id = coalesce(m.by_num, m.by_addr, m.by_phone, m.by_name)
  JOIN customers c ON c.id = coalesce(c0.merged_into_id, c0.id);
END $$;

-- the file's own table (every column except bank details), to show it the way the bank sends it
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pap_inbox' AND column_name = 'tbl') THEN
    ALTER TABLE public.pap_inbox ADD COLUMN cols jsonb, ADD COLUMN tbl jsonb;
  END IF;
END $$;

-- Mark (an emailed list or a file uploaded by hand): keep the matching values (customer #, name, phone, amount, response)
-- and the file's table. p_cols / p_tbl never hold bank columns: the page leaves those out before sending.
DROP FUNCTION IF EXISTS public.pap_inbox_save(bigint, text, text, jsonb, jsonb);
CREATE OR REPLACE FUNCTION public.pap_inbox_save(p_id bigint, p_file text, p_list text, p_head jsonb, p_rows jsonb, p_cols jsonb DEFAULT NULL, p_tbl jsonb DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id bigint; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF p_list NOT IN ('monthly', 'other') THEN RAISE EXCEPTION 'Pick a list'; END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'No rows'; END IF;
  p_rows := (SELECT coalesce(jsonb_agg(jsonb_build_array(left(coalesce(x ->> 0, ''), 60), left(coalesce(x ->> 1, ''), 200), left(coalesce(x ->> 2, ''), 40),
                                                         left(coalesce(x ->> 3, ''), 20), left(coalesce(x ->> 4, ''), 80)) ORDER BY k), '[]')
             FROM jsonb_array_elements(p_rows) WITH ORDINALITY t(x, k) WHERE jsonb_typeof(x) = 'array');
  IF p_tbl IS NOT NULL AND (jsonb_typeof(p_tbl) <> 'array' OR jsonb_array_length(p_tbl) <> jsonb_array_length(p_rows)) THEN p_tbl := NULL; p_cols := NULL; END IF;
  IF p_id IS NOT NULL THEN
    UPDATE pap_inbox SET head = p_head, rows = p_rows, pap_list = p_list, note = NULL, status = 'done', done_at = now(), done_by = v_me,
           cols = coalesce(p_cols, cols), tbl = CASE WHEN p_tbl IS NOT NULL THEN p_tbl WHEN jsonb_array_length(coalesce(tbl, '[]')) = jsonb_array_length(p_rows) THEN tbl END
    WHERE id = p_id RETURNING id INTO v_id;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO pap_inbox (message_id, received_at, from_name, subject, file_name, pap_list, head, rows, cols, tbl, status, done_at, done_by)
    VALUES ('upload:' || gen_random_uuid(), now(), coalesce(public._emp_name((SELECT employee_id FROM app_users WHERE id = v_me)), 'Uploaded'),
            'Uploaded on the Security page', left(coalesce(p_file, 'Uploaded file'), 200), p_list, p_head, p_rows, p_cols, p_tbl, 'done', now(), v_me)
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.pap_inbox_save(bigint, text, text, jsonb, jsonb, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_inbox_save(bigint, text, text, jsonb, jsonb, jsonb, jsonb) TO authenticated;

-- The EFT files that can be shown (newest first)
CREATE OR REPLACE FUNCTION public.pap_file_list()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE
    (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'file', i.file_name, 'received', i.received_at, 'status', i.status, 'list', i.pap_list,
              'count', jsonb_array_length(i.rows), 'upload', i.message_id LIKE 'upload:%', 'mail_id', i.mail_id) ORDER BY i.received_at DESC NULLS LAST, i.id DESC), '[]')
     FROM pap_inbox i WHERE i.rows IS NOT NULL AND jsonb_array_length(i.rows) > 0 AND i.status <> 'ignored') END
$$;

-- One EFT file, the way the bank sent it, with the customer each row matches
CREATE OR REPLACE FUNCTION public.pap_file_view(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '60s' AS $$
DECLARE v jsonb; f pap_inbox;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RETURN NULL; END IF;
  SELECT * INTO f FROM pap_inbox WHERE id = p_id;
  IF f.id IS NULL OR f.rows IS NULL THEN RETURN NULL; END IF;
  WITH k AS (SELECT (t.k)::int AS n, t.x FROM jsonb_array_elements(f.rows) WITH ORDINALITY t(x, k)),
  m AS (SELECT * FROM public.pap_match((SELECT coalesce(jsonb_agg(jsonb_build_object('i', k.n, 'num', k.x ->> 0, 'name', k.x ->> 1, 'phone', k.x ->> 2)), '[]') FROM k)))
  SELECT jsonb_build_object('id', f.id, 'file', f.file_name, 'received', f.received_at, 'list', f.pap_list, 'status', f.status, 'mail_id', f.mail_id,
      'cols', coalesce(f.cols, '["Customer #", "Name", "Phone", "Amount", "Response"]'::jsonb),
      'n', (SELECT count(*) FROM k), 'found', (SELECT count(*) FROM m),
      'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object(
          'cells', coalesce(f.tbl -> (k.n - 1), k.x), 'num', k.x ->> 0, 'name', k.x ->> 1, 'amount', k.x ->> 3, 'response', k.x ->> 4,
          'customer_id', m.customer_id, 'customer_number', m.customer_number, 'customer_name', m.name, 'how', m.how, 'pap_list', m.pap_list,
          'address', (SELECT concat_ws(', ', l.street, l.city) FROM locations l WHERE l.customer_id = m.customer_id ORDER BY l.active DESC, l.id LIMIT 1))
        ORDER BY k.n), '[]') FROM k LEFT JOIN m ON m.i = k.n))
  INTO v;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION public.pap_file_list(), public.pap_file_view(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_file_list(), public.pap_file_view(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.pap_file_people()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '60s' AS $$
DECLARE v jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RETURN NULL; END IF;
  WITH e AS (
    SELECT i.id AS inbox_id, i.mail_id, i.file_name, i.received_at, i.pap_list AS file_list,
           btrim(coalesce(x ->> 0, '')) AS num, btrim(replace(coalesce(x ->> 1, ''), '&amp;', '&')) AS name, btrim(coalesce(x ->> 2, '')) AS phone,
           btrim(coalesce(x ->> 3, '')) AS amount, btrim(coalesce(x ->> 4, '')) AS response
    FROM pap_inbox i, jsonb_array_elements(i.rows) x
    WHERE i.rows IS NOT NULL AND i.status <> 'ignored' AND jsonb_typeof(x) = 'array'),
  k AS (SELECT e.*, coalesce(nullif(lower(e.num), ''), lower(e.name) || '|' || right(regexp_replace(e.phone, '\D', '', 'g'), 10)) || '|' || lower(e.name) AS key FROM e
        WHERE e.num <> '' OR e.name <> '' OR e.phone <> ''),
  c AS (SELECT key, count(DISTINCT inbox_id) AS files FROM k GROUP BY key),
  r AS (SELECT DISTINCT ON (k.key) k.*, c.files, (row_number() OVER ())::int AS n
        FROM k JOIN c USING (key) ORDER BY k.key, k.received_at DESC NULLS LAST, k.inbox_id DESC),
  m AS (SELECT * FROM public.pap_match((SELECT coalesce(jsonb_agg(jsonb_build_object('i', r.n, 'num', r.num, 'name', r.name, 'phone', r.phone)), '[]') FROM r)))
  SELECT jsonb_build_object(
    'n', (SELECT count(*) FROM r),
    'found', (SELECT count(*) FROM m),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
       'num', r.num, 'name', r.name, 'phone', r.phone, 'amount', r.amount, 'response', r.response,
       'file', r.file_name, 'received', r.received_at, 'mail_id', r.mail_id, 'file_list', r.file_list, 'files', r.files,
       'customer_id', m.customer_id, 'customer_number', m.customer_number, 'customer_name', m.name, 'how', m.how, 'pap_list', m.pap_list,
       'address', (SELECT concat_ws(', ', l.street, l.city) FROM locations l WHERE l.customer_id = m.customer_id ORDER BY l.active DESC, l.id LIMIT 1))
       ORDER BY lower(coalesce(nullif(r.name, ''), m.name, r.num))), '[]'))
  INTO v
  FROM r LEFT JOIN m ON m.i = r.n;
  RETURN v;
END $$;

NOTIFY pgrst, 'reload schema';

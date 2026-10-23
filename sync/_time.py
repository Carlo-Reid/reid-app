import os, sys, time, json
sys.path.insert(0, "sync"); import eft_mail as m
db = m.connect_db(); cur = db.cursor()
cur.execute("SET statement_timeout = '120s'")
cur.execute("SELECT count(*) FROM customers"); nc = cur.fetchone()[0]
cur.execute("SELECT count(*) FROM locations"); nl = cur.fetchone()[0]
cur.execute("SELECT id, rows FROM pap_inbox WHERE rows IS NOT NULL ORDER BY id")
for iid, rows in cur.fetchall():
    p = json.dumps([{"i": k + 1, "num": r[0], "name": r[1], "phone": r[2]} for k, r in enumerate(rows)])
    q = """WITH x AS (WITH r0 AS MATERIALIZED (
    SELECT x.i, nullif(regexp_replace(btrim(coalesce(x.num, '')), '\.0+$', ''), '') AS num,
           nullif(btrim(regexp_replace(lower(replace(coalesce(x.name, ''), '&amp;', '&')), '\s+', ' ', 'g')), '') AS nm,
           nullif(right(regexp_replace(coalesce(x.phone, ''), '\D', '', 'g'), 10), '') AS ph
    FROM jsonb_to_recordset(%(p)s::jsonb) AS x(i int, num text, name text, phone text)),
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
                AND lower(regexp_replace(btrim(l.street), '^[0-9]+\s*', '')) LIKE r.a_st || '%%'
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
  JOIN customers c ON c.id = coalesce(c0.merged_into_id, c0.id)) SELECT how, count(*) FROM x GROUP BY how"""
    t = time.time(); cur.execute(q, {"p": p}); res = cur.fetchall(); dt = time.time() - t
    print(f"::notice::list {iid}: {len(rows)} rows matched in {dt:.1f}s: {dict(res)} (customers {nc}, locations {nl})", flush=True)

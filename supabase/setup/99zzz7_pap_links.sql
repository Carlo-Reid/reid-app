-- =====================================================================
-- Security page, EFT lists: click a row to see the customer's details; for a row that wasn't found (or was matched to the
-- wrong person), search for the customer and link them by hand. The link is remembered (by the name and reference in the
-- bank's file), so the same person matches on their own in later files too. Owners only.
-- Needs 99zzz6. Safe to run more than once.
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.pap_links (
  id           bigserial PRIMARY KEY,
  name_key     text NOT NULL,
  ref_key      text NOT NULL DEFAULT '',
  customer_id  bigint NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  set_by       bigint,
  set_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (name_key, ref_key));
ALTER TABLE public.pap_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_links FROM anon, authenticated;

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
  bylink AS MATERIALIZED (SELECT DISTINCT ON (r.i) r.i, k.customer_id AS id FROM r
              JOIN pap_links k ON k.name_key = coalesce(r.nm, '') AND k.ref_key = lower(coalesce(r.num, ''))
              ORDER BY r.i, k.set_at DESC),
  m AS MATERIALIZED (
    SELECT r.i, lk.id AS by_link, bn.id AS by_num, CASE WHEN a.n = 1 THEN a.id END AS by_addr, CASE WHEN p.n = 1 THEN p.id END AS by_phone, CASE WHEN b.n = 1 THEN b.id END AS by_name
    FROM r
    LEFT JOIN bylink lk ON lk.i = r.i
    LEFT JOIN bynum bn ON bn.i = r.i
    LEFT JOIN byaddr a ON a.i = r.i
    LEFT JOIN byphone p ON p.ph = r.ph
    LEFT JOIN byname b ON b.i = r.i)
  SELECT m.i, c.id, c.customer_number, c.display_name,
         CASE WHEN m.by_link IS NOT NULL THEN 'manual' WHEN m.by_num IS NOT NULL THEN 'number' WHEN m.by_addr IS NOT NULL THEN 'address' WHEN m.by_phone IS NOT NULL THEN 'phone' ELSE 'name' END,
         c.pap_list
  FROM m
  JOIN customers c0 ON c0.id = coalesce(m.by_link, m.by_num, m.by_addr, m.by_phone, m.by_name)
  JOIN customers c ON c.id = coalesce(c0.merged_into_id, c0.id);
END $$;

-- Link a row of the bank's file to a customer (p_customer NULL = forget the link)
CREATE OR REPLACE FUNCTION public.pap_link_set(p_ref text, p_name text, p_customer bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_name text := coalesce(nullif(btrim(regexp_replace(lower(replace(coalesce(p_name, ''), '&amp;', '&')), '\s+', ' ', 'g')), ''), '');
        v_ref text := lower(coalesce(nullif(regexp_replace(btrim(coalesce(p_ref, '')), '\.0+$', ''), ''), ''));
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF v_name = '' AND v_ref = '' THEN RAISE EXCEPTION 'Nothing to link'; END IF;
  IF p_customer IS NULL THEN
    DELETE FROM pap_links WHERE name_key = v_name AND ref_key = v_ref;
  ELSE
    INSERT INTO pap_links (name_key, ref_key, customer_id, set_by) VALUES (v_name, v_ref, p_customer, public.current_app_user_id())
    ON CONFLICT (name_key, ref_key) DO UPDATE SET customer_id = EXCLUDED.customer_id, set_by = EXCLUDED.set_by, set_at = now();
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pap_links', coalesce(p_customer, 0), 'update', public.current_app_user_id(),
          jsonb_build_object('change', CASE WHEN p_customer IS NULL THEN 'EFT link removed' ELSE 'EFT row linked to customer' END, 'name', p_name, 'reference', p_ref));
END $$;

-- A customer's details for the panel under an EFT row
CREATE OR REPLACE FUNCTION public.pap_customer_card(p_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE
    (SELECT jsonb_build_object(
       'id', c.id, 'name', c.display_name, 'number', c.customer_number, 'status', to_jsonb(c) ->> 'status', 'pap_list', c.pap_list, 'pap_set_at', c.pap_set_at,
       'contacts', (SELECT coalesce(jsonb_agg(jsonb_build_object('kind', k.kind, 'value', k.value, 'primary', k.is_primary) ORDER BY k.is_primary DESC, k.id), '[]')
                    FROM customer_contacts k WHERE k.customer_id = c.id),
       'locations', (SELECT coalesce(jsonb_agg(jsonb_build_object('street', l.street, 'city', l.city, 'postal', coalesce(to_jsonb(l) ->> 'postal_code', to_jsonb(l) ->> 'zip'),
                       'active', l.active) ORDER BY l.active DESC, l.id), '[]') FROM locations l WHERE l.customer_id = c.id),
       'owing', (SELECT coalesce(sum(i.balance_due), 0) FROM invoices i WHERE i.customer_id = c.id AND i.status NOT IN ('void', 'draft') AND i.balance_due > 0.004),
       'invoices', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'number', x.invoice_number, 'date', x.invoice_date, 'total', x.total, 'balance', x.balance_due)
                       ORDER BY x.invoice_date DESC, x.id DESC), '[]')
                    FROM (SELECT * FROM invoices i WHERE i.customer_id = c.id AND i.status NOT IN ('void', 'draft') ORDER BY i.invoice_date DESC, i.id DESC LIMIT 5) x))
     FROM customers c WHERE c.id = p_id) END
$$;

REVOKE EXECUTE ON FUNCTION public.pap_link_set(text, text, bigint), public.pap_customer_card(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_link_set(text, text, bigint), public.pap_customer_card(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

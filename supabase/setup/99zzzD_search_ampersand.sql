-- =====================================================================
-- Customer search, everywhere: "&" is ignored (treated as a space), in what's typed and in the names on file.
-- "Carlo & Cathy", "Carlo&Cathy" and "Carlo Cathy" all find Carlo & Cathy Magliocchetti, and still rank first.
-- Safe to run more than once.
-- =====================================================================
-- a name for searching: lower case, "&" (and "&amp;") treated as a space, single spaces
CREATE OR REPLACE FUNCTION public._nm(t text) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT btrim(regexp_replace(regexp_replace(lower(coalesce(t, '')), '&amp;|&', ' ', 'g'), '\s+', ' ', 'g'))
$$;

CREATE OR REPLACE FUNCTION public.customer_find(p_q text, p_limit integer DEFAULT 25)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '20s' AS $$
DECLARE
  q text := public._nm(regexp_replace(coalesce(p_q, ''), '[%_\\]', '', 'g'));   -- "&" counts as a space; % and _ would be wildcards
  words text[];
  first text;
  digits text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
  lim int := least(greatest(coalesce(p_limit, 25), 1), 100);
  v jsonb;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Only staff can search'; END IF;
  IF q = '' THEN RETURN jsonb_build_object('total', 0, 'rows', '[]'::jsonb); END IF;
  words := regexp_split_to_array(q, ' ');
  first := words[1];
  WITH c AS (
    SELECT c.id, c.display_name, c.customer_number, c.status, c.pap_list, public._nm(c.display_name) AS nm,
           public._nm(coalesce(c.display_name, '') || ' ' || coalesce(c.company_name, '')) AS nm2
    FROM customers c WHERE c.merged_into_id IS NULL),
  byname AS (
    SELECT c.id,
           CASE WHEN c.nm LIKE q || '%' THEN 1
                WHEN (' ' || c.nm) LIKE '% ' || q || '%' OR (' ' || c.nm2) LIKE '% ' || q || '%' THEN 2
                WHEN c.nm LIKE first || '%' THEN 2
                ELSE 3 END AS rank
    FROM c
    WHERE (SELECT bool_and(c.nm2 LIKE '%' || w || '%') FROM unnest(words) w)
      AND (length(q) >= 2 OR c.nm LIKE q || '%' OR (' ' || c.nm) LIKE '% ' || q || '%')),   -- one letter: only names (or words) starting with it
  contact AS (   -- other people on the file (contact names)
    SELECT k.customer_id AS id, CASE WHEN (' ' || public._nm(k.contact_name)) LIKE '% ' || q || '%' THEN 2 ELSE 3 END AS rank
    FROM customer_contacts k
    WHERE length(q) >= 2 AND k.contact_name IS NOT NULL AND (SELECT bool_and(public._nm(k.contact_name) LIKE '%' || w || '%') FROM unnest(words) w)),
  other AS (   -- phone, address, customer #
    SELECT k.customer_id AS id, 4 AS rank FROM customer_contacts k
      WHERE length(digits) >= 4 AND length(digits) >= length(regexp_replace(q, '[\s()+.-]', '', 'g')) - 1   -- 4+ digits: 613 alone is nearly everyone
        AND regexp_replace(k.value, '\D', '', 'g') LIKE '%' || digits || '%'
    UNION SELECT l.customer_id, 4 FROM locations l WHERE length(q) >= 3 AND lower(l.street) LIKE '%' || q || '%'
    UNION SELECT c.id, 4 FROM c WHERE length(q) >= 2 AND lower(coalesce(c.customer_number, '')) LIKE q || '%'),
  hits AS (SELECT id, min(rank) AS rank FROM (SELECT * FROM byname UNION ALL SELECT * FROM contact UNION ALL SELECT * FROM other) x GROUP BY id),
  top AS (
    SELECT h.id, h.rank, c.display_name, c.customer_number, c.status, c.pap_list
    FROM hits h JOIN customers c ON c.id = h.id
    WHERE c.merged_into_id IS NULL
    ORDER BY h.rank, c.status <> 'active', lower(c.display_name), c.id LIMIT lim)
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM hits),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'customer_id', t.id, 'display_name', t.display_name, 'customer_number', t.customer_number, 'status', t.status, 'rank', t.rank,
      'street', (SELECT l.street FROM locations l WHERE l.customer_id = t.id ORDER BY l.active DESC, l.id LIMIT 1),
      'city', (SELECT l.city FROM locations l WHERE l.customer_id = t.id ORDER BY l.active DESC, l.id LIMIT 1),
      'phone', (SELECT k.value FROM customer_contacts k WHERE k.customer_id = t.id AND k.kind IN ('phone', 'mobile') ORDER BY k.is_primary DESC, k.id LIMIT 1))
      ORDER BY t.rank, t.status <> 'active', lower(t.display_name), t.id), '[]'))
  INTO v
  FROM top t;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.pap_find_customers(p_q text, p_limit integer DEFAULT 25)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '20s' AS $$
DECLARE
  q text := public._nm(regexp_replace(coalesce(p_q, ''), '[%_\\]', '', 'g'));   -- "&" counts as a space; % and _ would be wildcards
  words text[];
  first text;
  digits text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
  lim int := least(greatest(coalesce(p_limit, 25), 1), 100);
  v jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RETURN NULL; END IF;
  IF q = '' THEN RETURN jsonb_build_object('total', 0, 'rows', '[]'::jsonb); END IF;
  words := regexp_split_to_array(q, ' ');
  first := words[1];
  WITH c AS (
    SELECT c.id, c.display_name, c.customer_number, c.status, c.pap_list, public._nm(c.display_name) AS nm,
           public._nm(coalesce(c.display_name, '') || ' ' || coalesce(c.company_name, '')) AS nm2
    FROM customers c WHERE c.merged_into_id IS NULL),
  byname AS (
    SELECT c.id,
           CASE WHEN c.nm LIKE q || '%' THEN 1
                WHEN (' ' || c.nm) LIKE '% ' || q || '%' OR (' ' || c.nm2) LIKE '% ' || q || '%' THEN 2
                WHEN c.nm LIKE first || '%' THEN 2
                ELSE 3 END AS rank
    FROM c
    WHERE (SELECT bool_and(c.nm2 LIKE '%' || w || '%') FROM unnest(words) w)
      AND (length(q) >= 2 OR c.nm LIKE q || '%' OR (' ' || c.nm) LIKE '% ' || q || '%')),   -- one letter: only names (or words) starting with it
  other AS (   -- phone, address, customer #
    SELECT k.customer_id AS id, 4 AS rank FROM customer_contacts k
      WHERE length(digits) >= 4 AND length(digits) >= length(regexp_replace(q, '[\s()+.-]', '', 'g')) - 1   -- 4+ digits: 613 alone is nearly everyone
        AND regexp_replace(k.value, '\D', '', 'g') LIKE '%' || digits || '%'
    UNION SELECT l.customer_id, 4 FROM locations l WHERE length(q) >= 3 AND lower(l.street) LIKE '%' || q || '%'
    UNION SELECT c.id, 4 FROM c WHERE length(q) >= 2 AND lower(coalesce(c.customer_number, '')) LIKE q || '%'),
  hits AS (SELECT id, min(rank) AS rank FROM (SELECT * FROM byname UNION ALL SELECT * FROM other) x GROUP BY id),
  top AS (
    SELECT h.id, h.rank, c.display_name, c.customer_number, c.status, c.pap_list
    FROM hits h JOIN customers c ON c.id = h.id
    WHERE c.merged_into_id IS NULL
    ORDER BY h.rank, lower(c.display_name), c.id LIMIT lim),
  bu AS (SELECT id, name ILIKE '%monitor%' AS mon FROM business_units WHERE name ILIKE '%secur%'),
  inv AS (SELECT i.customer_id, bool_or(bu.mon) AS mon, max(i.invoice_date) AS last, max(i.invoice_date) FILTER (WHERE bu.mon) AS last_mon
          FROM invoices i JOIN bu ON bu.id = i.business_unit_id
          WHERE i.customer_id IN (SELECT id FROM top) AND i.status NOT IN ('void', 'draft') GROUP BY i.customer_id),
  jb AS (SELECT DISTINCT j.customer_id FROM jobs j JOIN job_types t ON t.id = j.job_type_id
         WHERE j.customer_id IN (SELECT id FROM top) AND (t.job_class = 'security' OR t.name ILIKE '%secur%' OR t.name ILIKE '%alarm%'))
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM hits),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'customer_id', t.id, 'display_name', t.display_name, 'customer_number', t.customer_number, 'status', t.status, 'rank', t.rank,
      'street', (SELECT l.street FROM locations l WHERE l.customer_id = t.id ORDER BY l.active DESC, l.id LIMIT 1),
      'city', (SELECT l.city FROM locations l WHERE l.customer_id = t.id ORDER BY l.active DESC, l.id LIMIT 1),
      'phone', (SELECT k.value FROM customer_contacts k WHERE k.customer_id = t.id AND k.kind IN ('phone', 'mobile') ORDER BY k.is_primary DESC, k.id LIMIT 1),
      'flags', jsonb_build_object('monitoring', coalesce(inv.mon, false), 'security', inv.customer_id IS NOT NULL OR jb.customer_id IS NOT NULL,
                                  'last', inv.last, 'last_monitoring', inv.last_mon, 'pap_list', t.pap_list))
      ORDER BY t.rank, lower(t.display_name), t.id), '[]'))
  INTO v
  FROM top t LEFT JOIN inv ON inv.customer_id = t.id LEFT JOIN jb ON jb.customer_id = t.id;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.search_customers(p_name text DEFAULT NULL, p_phone text DEFAULT NULL, p_address text DEFAULT NULL,
                                                   p_limit int DEFAULT 60, p_any text DEFAULT NULL,
                                                   p_last text DEFAULT NULL, p_email text DEFAULT NULL, p_model text DEFAULT NULL)
RETURNS TABLE (customer_id bigint, display_name text, status text, street text, city text, phone text, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE
  v_name  text[] := array_remove(string_to_array(public._nm(p_name), ' '), '');   -- "&" counts as a space
  v_addr  text[] := array_remove(string_to_array(lower(btrim(coalesce(p_address, ''))), ' '), '');
  v_phone text   := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_any   text   := regexp_replace(lower(btrim(coalesce(p_any, ''))), '\s*(&amp;|&)\s*', '%', 'g');   -- "carlo & cathy" also finds "Carlo Cathy"
  v_anyd  text   := regexp_replace(coalesce(p_any, ''), '\D', '', 'g');
  v_last  text   := replace(replace(public._nm(p_last), '%', ''), '_', '\_');
  v_email text   := replace(replace(lower(btrim(coalesce(p_email, ''))), '%', ''), '_', '\_');
  v_model text   := regexp_replace(lower(coalesce(p_model, '')), '[^a-z0-9]', '', 'g');
  -- what to rank by: the name words, else the last name, else the big box
  v_key   text   := replace(replace(coalesce(nullif(public._nm(p_name), ''), nullif(public._nm(p_last), ''), nullif(public._nm(p_any), ''), ''), '%', ''), '_', '');
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Only staff can search'; END IF;
  IF cardinality(v_name) = 0 AND cardinality(v_addr) = 0 AND length(v_phone) < 3 AND length(v_any) < 2
     AND length(v_last) < 2 AND length(v_email) < 2 AND length(v_model) < 2 THEN RETURN; END IF;
  IF length(v_phone) = 11 AND left(v_phone, 1) = '1' THEN v_phone := substr(v_phone, 2); END IF;
  RETURN QUERY
  WITH name_pats AS (SELECT array_agg('%' || w || '%') AS pats FROM unnest(v_name) w),
       addr_pats AS (SELECT array_agg('%' || w || '%') AS pats FROM unnest(v_addr) w),
  name_ids AS (
    SELECT c.id FROM customers c, name_pats n WHERE cardinality(v_name) > 0 AND c.display_name ILIKE ALL (n.pats)
    UNION
    SELECT cc.customer_id FROM customer_contacts cc, name_pats n WHERE cardinality(v_name) > 0 AND cc.contact_name ILIKE ALL (n.pats)),
  -- last name: a word after the first one starts with it ("hunt" finds Ronald Hunt and Mary & Bob Hunter)
  last_ids AS (
    SELECT c.id FROM customers c WHERE length(v_last) >= 2 AND ' ' || public._nm(c.display_name) LIKE '% ' || v_last || '%'
    UNION
    SELECT cc.customer_id FROM customer_contacts cc WHERE length(v_last) >= 2 AND cc.contact_name ILIKE '% ' || v_last || '%'),
  phone_ids AS (SELECT DISTINCT cc.customer_id FROM customer_contacts cc WHERE length(v_phone) >= 3 AND cc.value_digits LIKE '%' || v_phone || '%'),
  email_ids AS (SELECT DISTINCT cc.customer_id FROM customer_contacts cc WHERE length(v_email) >= 2 AND cc.kind = 'email' AND cc.value ILIKE '%' || v_email || '%'),
  model_ids AS (   -- dashes and spaces don't matter: "TM9E 060" finds TM9E060
    SELECT DISTINCT l.customer_id FROM equipment e JOIN locations l ON l.id = e.location_id
    WHERE length(v_model) >= 2 AND (e.model_number ILIKE '%' || btrim(p_model) || '%'
       OR regexp_replace(lower(e.model_number), '[^a-z0-9]', '', 'g') LIKE '%' || v_model || '%')),
  addr_ids AS (
    SELECT DISTINCT l.customer_id FROM locations l, addr_pats a
    WHERE cardinality(v_addr) > 0
      AND concat_ws(' ', l.street, l.unit, l.city, l.postal_code, replace(coalesce(l.postal_code, ''), ' ', '')) ILIKE ALL (a.pats)),
  any_ids AS (
    SELECT DISTINCT s.customer_id FROM search_index s
    WHERE length(v_any) >= 2 AND s.customer_id IS NOT NULL
      AND (s.search_text LIKE '%' || v_any || '%'
           OR (length(v_anyd) >= 4 AND s.search_text LIKE '%' || v_anyd || '%'))),
  hits AS (
    SELECT c.id, c.display_name, c.status FROM customers c
    WHERE (cardinality(v_name) = 0 OR c.id IN (SELECT id FROM name_ids))
      AND (length(v_last) < 2 OR c.id IN (SELECT id FROM last_ids))
      AND (length(v_phone) < 3 OR c.id IN (SELECT customer_id FROM phone_ids))
      AND (length(v_email) < 2 OR c.id IN (SELECT customer_id FROM email_ids))
      AND (length(v_model) < 2 OR c.id IN (SELECT customer_id FROM model_ids))
      AND (cardinality(v_addr) = 0 OR c.id IN (SELECT customer_id FROM addr_ids))
      AND (length(v_any) < 2 OR c.id IN (SELECT customer_id FROM any_ids))
  )
  SELECT h.id, h.display_name, h.status,
         (SELECT l.street FROM locations l WHERE l.customer_id = h.id ORDER BY l.active DESC, l.id LIMIT 1),
         (SELECT l.city FROM locations l WHERE l.customer_id = h.id ORDER BY l.active DESC, l.id LIMIT 1),
         (SELECT cc.value FROM customer_contacts cc WHERE cc.customer_id = h.id AND cc.kind <> 'email'
            ORDER BY (length(v_phone) >= 3 AND cc.value_digits LIKE '%' || v_phone || '%') DESC, cc.is_primary DESC, cc.id LIMIT 1),
         count(*) OVER ()
  FROM hits h
  -- best matches first: the name starts with what's typed, then a word in it starts with it, then it's anywhere in the name
  ORDER BY CASE WHEN v_key = '' THEN 9
                WHEN public._nm(h.display_name) LIKE v_key || '%' THEN 1
                WHEN ' ' || public._nm(h.display_name) LIKE '% ' || v_key || '%' THEN 2
                WHEN public._nm(h.display_name) LIKE '%' || v_key || '%' THEN 3 ELSE 4 END,
           h.status <> 'active', lower(regexp_replace(h.display_name, '^[^[:alnum:]]+', ''))
  LIMIT least(coalesce(p_limit, 60), 200);
END $$;

NOTIFY pgrst, 'reload schema';

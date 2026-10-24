-- =====================================================================
-- Security page: the customer search under an EFT row searches as you type, best matches first:
--   1. the name starts with what's typed ("car" -> Carlo, Carleton)
--   2. a word in the name starts with it (John Carter)
--   3. the name has it anywhere (Ricardo)
--   4. the phone, address or customer # matches
-- Several words ("carlo mil") must all match. Each customer comes with the security badges (Monitoring / Security / PAP).
-- Owners only. Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.pap_find_customers(p_q text, p_limit integer DEFAULT 25)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '20s' AS $$
DECLARE
  q text := btrim(regexp_replace(regexp_replace(lower(coalesce(p_q, '')), '[%_\\]', '', 'g'), '\s+', ' ', 'g'));   -- (% and _ would be wildcards)
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
    SELECT c.id, c.display_name, c.customer_number, c.status, c.pap_list, lower(coalesce(c.display_name, '')) AS nm,
           lower(coalesce(c.display_name, '') || ' ' || coalesce(c.company_name, '')) AS nm2
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
REVOKE EXECUTE ON FUNCTION public.pap_find_customers(text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_find_customers(text, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';

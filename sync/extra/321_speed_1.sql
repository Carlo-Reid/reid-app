-- 321_speed_1.sql  (Carlo, Nov 19, 2026: "the program is slow to load and open pages")
-- Speed, round 1. Nothing here changes what a page shows; only how the answer is found.
--   1. The three map lists (towns, communities, postal areas) added up every address on every call
--      (0.7 to 1 second each). The answer is now kept in map_list_cache and worked out again only
--      when an address, a zone, a town colour, a community or a neighbourhood changes.
--   2. pb_categories asked "who is this person, what may they see" again for each of 700 groups.
--      It now asks once.
--   3. customer_find read every customer, contact and address for each letter typed.
--      It now uses word indexes (pg_trgm) when 3 or more letters are typed.
-- This file runs after the older files on every sync, so these versions win.

-- ---------------------------------------------------------------- 1. the map lists
CREATE TABLE IF NOT EXISTS public.map_list_cache (
  k  text PRIMARY KEY,
  v  jsonb,
  at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.map_list_cache ENABLE ROW LEVEL SECURITY;   -- no policy: only the functions below read it
REVOKE ALL ON public.map_list_cache FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._town_list_calc() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public SET jit = off AS $$
  SELECT jsonb_build_object(
    'towns', (WITH base AS (SELECT lower(btrim(city)) k, initcap(btrim(city)) nm, upper(left(replace(postal_code, ' ', ''), 3)) f FROM locations WHERE btrim(coalesce(city, '')) <> ''),
                   fs AS (SELECT k, jsonb_agg(f ORDER BY c DESC) FILTER (WHERE rn <= 3) fsas FROM (
                            SELECT k, f, count(*) c, row_number() OVER (PARTITION BY k ORDER BY count(*) DESC) rn FROM base WHERE f IS NOT NULL GROUP BY k, f) x GROUP BY k),
                   t AS (SELECT k, mode() WITHIN GROUP (ORDER BY nm) nm, count(*) n FROM base GROUP BY k HAVING count(*) >= 2)
              SELECT coalesce(jsonb_agg(jsonb_build_object('key', t.k, 'name', t.nm, 'n', t.n, 'color', tc.color, 'fsas', fs.fsas) ORDER BY t.n DESC), '[]')
              FROM t LEFT JOIN fs ON fs.k = t.k
              LEFT JOIN town_colours tc ON tc.town = t.k))
$$;

CREATE OR REPLACE FUNCTION public._postal_zone_calc() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public SET jit = off AS $$
  SELECT jsonb_build_object(
    'zones', (SELECT coalesce(jsonb_agg(jsonb_build_object('prefix', prefix, 'name', name, 'color', color) ORDER BY prefix), '[]') FROM postal_zones),
    'areas', (SELECT coalesce(jsonb_agg(jsonb_build_object('fsa', fsa, 'n', n, 'city', city) ORDER BY fsa), '[]') FROM (
                SELECT upper(left(regexp_replace(postal_code, '\s', '', 'g'), 3)) fsa, count(*) n, mode() WITHIN GROUP (ORDER BY initcap(btrim(city))) city
                FROM locations WHERE postal_code ~* '^\s*[a-z][0-9][a-z]' GROUP BY 1 HAVING count(*) >= 3) a))
$$;

CREATE OR REPLACE FUNCTION public._community_list_calc() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public SET jit = off AS $$
  WITH l AS MATERIALIZED (SELECT community_id c, neighbourhood_id h, upper(left(replace(postal_code, ' ', ''), 3)) f FROM locations WHERE community_id IS NOT NULL),
       cnt AS (SELECT c, count(*) n FROM l GROUP BY c),
       hd AS (SELECT DISTINCT ON (c) c, h FROM (SELECT c, h, count(*) k FROM l WHERE h IS NOT NULL GROUP BY c, h) x ORDER BY c, k DESC),
       fs AS (SELECT c, jsonb_agg(f ORDER BY k DESC) fsas FROM (SELECT c, f, count(*) k, row_number() OVER (PARTITION BY c ORDER BY count(*) DESC) rn FROM l WHERE f <> '' GROUP BY c, f) x WHERE rn <= 3 GROUP BY c)
  SELECT jsonb_build_object(
    'communities', coalesce((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'kind', c.kind, 'lat', c.lat, 'lng', c.lng, 'color', c.color, 'hidden', c.hidden,
                      'n', coalesce(cnt.n, 0), 'hood', nb.name, 'fsas', fs.fsas) ORDER BY c.name)
                    FROM communities c LEFT JOIN cnt ON cnt.c = c.id LEFT JOIN hd ON hd.c = c.id LEFT JOIN neighbourhoods nb ON nb.id = hd.h LEFT JOIN fs ON fs.c = c.id), '[]'),
    'located', (SELECT coalesce(sum(n), 0) FROM cnt),
    -- the old town for each postal area, from what customers there write (K2J -> Nepean), for addresses that just say "Ottawa"
    'ptowns', (WITH g AS (SELECT upper(left(replace(postal_code, ' ', ''), 4)) p4, lower(btrim(city)) c, count(*) n FROM locations
                          WHERE postal_code ~ '^[A-Za-z][0-9]' AND btrim(coalesce(city, '')) <> '' GROUP BY 1, 2),
                    g2 AS (SELECT p4, t, sum(n) n FROM (SELECT p4, public._town_name(c) t, n FROM g) x WHERE t IS NOT NULL GROUP BY 1, 2),
                    b AS (SELECT p4 p, t, n FROM g2 UNION ALL SELECT left(p4, 3), t, sum(n) FROM g2 GROUP BY 1, 2),
                    tot AS (SELECT p, sum(n) n, sum(n) FILTER (WHERE lower(t) <> 'ottawa') nn FROM b GROUP BY p),
                    best AS (SELECT DISTINCT ON (p) p, t, n k FROM b WHERE lower(t) <> 'ottawa' ORDER BY p, n DESC)
               SELECT coalesce(jsonb_object_agg(best.p, best.t), '{}') FROM best JOIN tot USING (p) WHERE best.k >= 3 AND best.k * 1.0 / tot.nn >= 0.6 AND best.k * 1.0 / tot.n >= 0.25),
    'total', (SELECT count(*) FROM locations))
$$;

-- the kept answer; worked out again when it is missing or a day old
CREATE OR REPLACE FUNCTION public._map_cached(p_k text) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE x jsonb;
BEGIN
  SELECT v INTO x FROM map_list_cache WHERE k = p_k AND at > now() - interval '24 hours';
  IF FOUND THEN RETURN x; END IF;
  x := CASE p_k WHEN 'town' THEN public._town_list_calc()
                WHEN 'zone' THEN public._postal_zone_calc()
                WHEN 'community' THEN public._community_list_calc() END;
  IF x IS NULL THEN RETURN NULL; END IF;
  INSERT INTO map_list_cache (k, v, at) VALUES (p_k, x, now())
  ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v, at = now();
  RETURN x;
END $$;

REVOKE ALL ON FUNCTION public._town_list_calc(), public._postal_zone_calc(), public._community_list_calc(), public._map_cached(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.town_list() RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public SET jit = off AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE public._map_cached('town') END
$$;

CREATE OR REPLACE FUNCTION public.postal_zone_list() RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public SET jit = off AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL
              ELSE jsonb_build_object('can_edit', public._can_map_setup()) || public._map_cached('zone') END
$$;

CREATE OR REPLACE FUNCTION public.community_list() RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public SET jit = off AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE public._map_cached('community') END
$$;

-- forget the kept answers when something they are made from changes
CREATE OR REPLACE FUNCTION public._map_cache_clear() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM map_list_cache WHERE true;
  RETURN NULL;
END $$;

DO $$
DECLARE t text;
BEGIN
  -- an address: only when its city, postal code, community or neighbourhood changes (the sync touches every address, mostly with no change)
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'map_cache_loc_upd' AND tgrelid = 'public.locations'::regclass) THEN
    CREATE TRIGGER map_cache_loc_upd AFTER UPDATE ON public.locations FOR EACH ROW
      WHEN (OLD.city IS DISTINCT FROM NEW.city OR OLD.postal_code IS DISTINCT FROM NEW.postal_code
            OR OLD.community_id IS DISTINCT FROM NEW.community_id OR OLD.neighbourhood_id IS DISTINCT FROM NEW.neighbourhood_id)
      EXECUTE FUNCTION public._map_cache_clear();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'map_cache_loc_insdel' AND tgrelid = 'public.locations'::regclass) THEN
    CREATE TRIGGER map_cache_loc_insdel AFTER INSERT OR DELETE ON public.locations FOR EACH STATEMENT
      EXECUTE FUNCTION public._map_cache_clear();
  END IF;
  FOREACH t IN ARRAY ARRAY['postal_zones', 'town_colours', 'communities', 'neighbourhoods'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'map_cache_clear' AND tgrelid = ('public.' || t)::regclass) THEN
      EXECUTE format('CREATE TRIGGER map_cache_clear AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION public._map_cache_clear()', t);
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------- 2. the price book groups
CREATE OR REPLACE FUNCTION public.pb_categories()
RETURNS TABLE(id bigint, parent_id bigint, name text, active boolean, sort_order integer, items bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE
  v_full boolean; v_limited boolean := false; v_book bigint; v_bookcats boolean; v_me bigint;
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN; END IF;
  v_full := coalesce(public._pb_full(), false);
  IF NOT v_full THEN
    IF NOT coalesce(public.has_permission('pricebook.view'), false) THEN RETURN; END IF;
    v_me := public.current_app_user_id();
    v_limited := EXISTS (SELECT 1 FROM user_pb_categories u WHERE u.app_user_id = v_me);
  END IF;
  v_book := public._my_book();
  v_bookcats := v_book IS NOT NULL AND EXISTS (SELECT 1 FROM price_book_categories b WHERE b.book_id = v_book);
  RETURN QUERY
  WITH cnt AS (SELECT ic.category_id AS cid, count(*) AS k
               FROM pricebook_item_categories ic JOIN pricebook_items p ON p.id = ic.item_id AND p.active GROUP BY ic.category_id),
       mine AS (SELECT a.x FROM public._pb_my_cats() a(x) WHERE v_limited
                UNION SELECT a.x FROM public._pb_my_cat_parents() a(x) WHERE v_limited),
       bk AS (SELECT a.x FROM public._book_cats(v_book) a(x) WHERE v_bookcats
              UNION SELECT a.x FROM public._book_cat_parents(v_book) a(x) WHERE v_bookcats)
  SELECT c.id::bigint, c.parent_id::bigint, c.name::text, c.active::boolean, c.sort_order::integer, coalesce(cnt.k, 0)::bigint
  FROM pricebook_categories c LEFT JOIN cnt ON cnt.cid = c.id
  WHERE (NOT v_limited OR c.id IN (SELECT m.x FROM mine m))
    AND (NOT v_bookcats OR c.id IN (SELECT b2.x FROM bk b2))
  ORDER BY c.sort_order, lower(c.name), c.id;   -- c.id: two groups with the same name and order always come out the same way
END $$;

-- ---------------------------------------------------------------- 3. the customer search
CREATE INDEX IF NOT EXISTS customers_nm2_trgm ON public.customers USING gin (public._nm(coalesce(display_name, '') || ' ' || coalesce(company_name, '')) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS customer_contacts_cname_trgm ON public.customer_contacts USING gin (public._nm(contact_name) gin_trgm_ops) WHERE contact_name IS NOT NULL;
CREATE INDEX IF NOT EXISTS customer_contacts_digits_trgm ON public.customer_contacts USING gin (regexp_replace(value, '\D', '', 'g') gin_trgm_ops);
CREATE INDEX IF NOT EXISTS locations_street_lc_trgm ON public.locations USING gin (lower(street) gin_trgm_ops);

CREATE OR REPLACE FUNCTION public.customer_find(p_q text, p_limit integer DEFAULT 25) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '20s' AS $$
DECLARE
  q text := public._nm(regexp_replace(coalesce(p_q, ''), '[%_\\]', '', 'g'));   -- "&" counts as a space; % and _ would be wildcards
  words text[];
  first text;
  big text;      -- the longest word typed: the indexes find the rows that have it, then every word is checked
  digits text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
  lim int := least(greatest(coalesce(p_limit, 25), 1), 100);
  me bigint;
  v jsonb;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Only staff can search'; END IF;
  IF q = '' THEN RETURN jsonb_build_object('total', 0, 'rows', '[]'::jsonb); END IF;
  words := regexp_split_to_array(q, ' ');
  first := words[1];
  big := (SELECT w FROM unnest(words) w ORDER BY length(w) DESC LIMIT 1);
  me := public.current_app_user_id();
  WITH byname AS (
    SELECT c.id,
           CASE WHEN public._nm(c.display_name) LIKE q || '%' THEN 1
                WHEN (' ' || public._nm(c.display_name)) LIKE '% ' || q || '%'
                  OR (' ' || public._nm(coalesce(c.display_name, '') || ' ' || coalesce(c.company_name, ''))) LIKE '% ' || q || '%' THEN 2
                WHEN public._nm(c.display_name) LIKE first || '%' THEN 2
                ELSE 3 END AS rank
    FROM customers c
    WHERE c.merged_into_id IS NULL AND (c.practice_user_id IS NULL OR c.practice_user_id = me)
      AND public._nm(coalesce(c.display_name, '') || ' ' || coalesce(c.company_name, '')) LIKE '%' || big || '%'
      AND (SELECT bool_and(public._nm(coalesce(c.display_name, '') || ' ' || coalesce(c.company_name, '')) LIKE '%' || w || '%') FROM unnest(words) w)
      AND (length(q) >= 2 OR public._nm(c.display_name) LIKE q || '%' OR (' ' || public._nm(c.display_name)) LIKE '% ' || q || '%')),   -- one letter: only names (or words) starting with it
  contact AS (   -- other people on the file (contact names)
    SELECT k.customer_id AS id, CASE WHEN (' ' || public._nm(k.contact_name)) LIKE '% ' || q || '%' THEN 2 ELSE 3 END AS rank
    FROM customer_contacts k
    WHERE length(q) >= 2 AND k.contact_name IS NOT NULL
      AND public._nm(k.contact_name) LIKE '%' || big || '%'
      AND (SELECT bool_and(public._nm(k.contact_name) LIKE '%' || w || '%') FROM unnest(words) w)),
  other AS (   -- phone, address, customer #
    SELECT k.customer_id AS id, 4 AS rank FROM customer_contacts k
      WHERE length(digits) >= 4 AND length(digits) >= length(regexp_replace(q, '[\s()+.-]', '', 'g')) - 1   -- 4+ digits: 613 alone is nearly everyone
        AND regexp_replace(k.value, '\D', '', 'g') LIKE '%' || digits || '%'
    UNION SELECT l.customer_id, 4 FROM locations l WHERE length(q) >= 3 AND lower(l.street) LIKE '%' || q || '%'
    UNION SELECT c.id, 4 FROM customers c
      WHERE length(q) >= 2 AND c.merged_into_id IS NULL AND (c.practice_user_id IS NULL OR c.practice_user_id = me)
        AND lower(coalesce(c.customer_number, '')) LIKE q || '%'),
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

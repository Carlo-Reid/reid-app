-- =====================================================================
-- Improvement 9: speed.
--  * The map lists (towns, postal areas, communities, neighbourhoods) counted all 48,000 addresses every time a map
--    page opened (1 to 2 seconds each). Now the answer is kept for up to 6 hours and thrown away as soon as an address,
--    a colour, a community, a neighbourhood or a postal area changes, so it's always right and usually instant.
--  * The price book category list counted items once per category; now it counts them all in one go.
--  * "Is this a duplicate customer?" looked at every phone, email and address in the database; now it uses lookup lists (indexes).
--  * Index for invoices by customer and department (used by Receivables and the monitoring / security badges).
-- Safe to run more than once (and it puts itself back if an older setup file replaces the map lists).
-- =====================================================================
SET LOCAL lock_timeout = '15s';

CREATE TABLE IF NOT EXISTS public._list_cache (k text PRIMARY KEY, v jsonb, made_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public._list_cache ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public._list_cache FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._list_cache_clear() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN DELETE FROM _list_cache; RETURN NULL; END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['locations', 'town_colours', 'communities', 'neighbourhoods', 'postal_zones'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'zz_list_cache_clear' AND tgrelid = ('public.' || t)::regclass) THEN
      EXECUTE format('CREATE TRIGGER zz_list_cache_clear AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION public._list_cache_clear()', t);
    END IF;
  END LOOP;
END $$;

-- keep the real list makers under a new name (once, or again if a setup file put the old ones back)
DO $$
DECLARE f text; sig text;
BEGIN
  FOREACH sig IN ARRAY ARRAY['town_list()', 'postal_zone_list()', 'community_list()', 'neighbourhood_list(boolean)'] LOOP
    f := split_part(sig, '(', 1);
    IF to_regprocedure('public.' || sig) IS NOT NULL
       AND position('_list_cache' IN (SELECT prosrc FROM pg_proc WHERE oid = to_regprocedure('public.' || sig))) = 0 THEN
      EXECUTE format('DROP FUNCTION IF EXISTS public.%I(%s)', '_' || f || '_live', CASE WHEN sig LIKE '%boolean%' THEN 'boolean' ELSE '' END);
      EXECUTE format('ALTER FUNCTION public.%s RENAME TO %I', sig, '_' || f || '_live');
    END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public._list_cached(p_key text, p_sql text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r jsonb;
BEGIN
  SELECT v INTO r FROM _list_cache WHERE k = p_key AND made_at > now() - interval '6 hours';
  IF r IS NULL THEN
    EXECUTE p_sql INTO r;
    IF r IS NOT NULL THEN
      INSERT INTO _list_cache (k, v, made_at) VALUES (p_key, r, now()) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v, made_at = EXCLUDED.made_at;
    END IF;
  END IF;
  RETURN r;
END $$;
REVOKE EXECUTE ON FUNCTION public._list_cached(text, text), public._list_cache_clear() FROM PUBLIC, anon, authenticated;

DO $do$
BEGIN
  IF to_regprocedure('public._town_list_live()') IS NOT NULL THEN
    EXECUTE $f$CREATE OR REPLACE FUNCTION public.town_list() RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $b$
      BEGIN IF public.current_staff_role() IS NULL THEN RETURN NULL; END IF;
            RETURN public._list_cached('town_list', 'SELECT public._town_list_live()'); END $b$$f$;
  END IF;
  IF to_regprocedure('public._postal_zone_list_live()') IS NOT NULL THEN
    EXECUTE $f$CREATE OR REPLACE FUNCTION public.postal_zone_list() RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $b$
      BEGIN IF public.current_staff_role() IS NULL THEN RETURN NULL; END IF;
            RETURN public._list_cached('postal_zone_list', 'SELECT public._postal_zone_list_live()') || jsonb_build_object('can_edit', public._can_map_setup()); END $b$$f$;
  END IF;
  IF to_regprocedure('public._community_list_live()') IS NOT NULL THEN
    EXECUTE $f$CREATE OR REPLACE FUNCTION public.community_list() RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $b$
      BEGIN IF public.current_staff_role() IS NULL THEN RETURN NULL; END IF;
            RETURN public._list_cached('community_list', 'SELECT public._community_list_live()'); END $b$$f$;
  END IF;
  IF to_regprocedure('public._neighbourhood_list_live(boolean)') IS NOT NULL THEN
    EXECUTE $f$CREATE OR REPLACE FUNCTION public.neighbourhood_list(p_shapes boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $b$
      BEGIN IF public.current_staff_role() IS NULL THEN RETURN NULL; END IF;
            RETURN public._list_cached('neighbourhood_list:' || coalesce(p_shapes, false), format('SELECT public._neighbourhood_list_live(%L)', coalesce(p_shapes, false))); END $b$$f$;
  END IF;
END $do$;
DO $$
DECLARE sig text;
BEGIN
  FOREACH sig IN ARRAY ARRAY['town_list()', 'postal_zone_list()', 'community_list()', 'neighbourhood_list(boolean)'] LOOP
    IF to_regprocedure('public.' || sig) IS NOT NULL THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%s FROM PUBLIC, anon', sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', sig);
    END IF;
  END LOOP;
END $$;

-- price book categories: the same answer, counted in one go
DO $do$
BEGIN
  IF to_regprocedure('public._pb_full()') IS NOT NULL AND to_regprocedure('public._my_book()') IS NOT NULL THEN
    EXECUTE $f$
CREATE OR REPLACE FUNCTION public.pb_categories()
RETURNS TABLE(id bigint, parent_id bigint, name text, active boolean, sort_order integer, items bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET jit = off AS $b$
#variable_conflict use_column
DECLARE v_full boolean; v_limited boolean := false; v_mine bigint[]; v_book bigint; v_bookcats bigint[];
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN; END IF;
  v_full := coalesce(public._pb_full(), false);
  IF NOT v_full THEN
    IF NOT coalesce(public.has_permission('pricebook.view'), false) THEN RETURN; END IF;
    v_limited := EXISTS (SELECT 1 FROM user_pb_categories u WHERE u.app_user_id = public.current_app_user_id());
    IF v_limited THEN v_mine := ARRAY(SELECT x FROM public._pb_my_cats() x UNION SELECT x FROM public._pb_my_cat_parents() x); END IF;
  END IF;
  v_book := public._my_book();
  IF v_book IS NOT NULL AND EXISTS (SELECT 1 FROM price_book_categories b WHERE b.book_id = v_book) THEN
    v_bookcats := ARRAY(SELECT x FROM public._book_cats(v_book) x UNION SELECT x FROM public._book_cat_parents(v_book) x);
  END IF;
  RETURN QUERY
    WITH cnt AS (SELECT ic.category_id AS cid, count(*) AS n FROM pricebook_item_categories ic JOIN pricebook_items p ON p.id = ic.item_id AND p.active GROUP BY ic.category_id)
    SELECT c.id, c.parent_id, c.name, c.active, c.sort_order, coalesce(cnt.n, 0)::bigint
    FROM pricebook_categories c LEFT JOIN cnt ON cnt.cid = c.id
    WHERE (v_full OR NOT v_limited OR c.id = ANY (v_mine))
      AND (v_bookcats IS NULL OR c.id = ANY (v_bookcats))
    ORDER BY c.sort_order, lower(c.name);
END $b$$f$;
  END IF;
END $do$;

-- lookup lists for "is this a duplicate?" and for invoices by customer and department
CREATE INDEX IF NOT EXISTS customer_contacts_norm_phone_idx ON public.customer_contacts (public._norm_contact('phone', value)) WHERE kind IN ('phone', 'mobile');
CREATE INDEX IF NOT EXISTS customer_contacts_norm_email_idx ON public.customer_contacts (public._norm_contact('email', value)) WHERE kind = 'email';
CREATE INDEX IF NOT EXISTS locations_addr_key_idx ON public.locations ((upper(regexp_replace(street, '[^A-Za-z0-9]', '', 'g')) || '|' || coalesce(upper(replace(postal_code, ' ', '')), upper(city)))) WHERE active;
CREATE INDEX IF NOT EXISTS invoices_customer_bu_idx ON public.invoices (customer_id, business_unit_id);

NOTIFY pgrst, 'reload schema';

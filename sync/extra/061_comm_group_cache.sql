-- Sales / Installs pages were slow: every commission line worked out its commission group from the price book
-- (walking the item's categories and matching keywords) every time. Now each item's group is remembered in a small table.
-- It is cleared when the groups, an item, or the categories change, and refilled quietly (the Sales page asks, and the nightly sync).
-- An item that isn't in the table yet is worked out the old way, so the numbers never change, only the speed.
CREATE TABLE IF NOT EXISTS public.comm_item_group_cache (item_id bigint PRIMARY KEY, group_id bigint, filled_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.comm_item_group_cache ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.comm_item_group_cache FROM anon, authenticated;

-- the old way, kept under a new name
CREATE OR REPLACE FUNCTION public._comm_group_live(p_item bigint)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  WITH RECURSIVE cats AS (
    SELECT c.id, c.parent_id, c.name, 0 AS d FROM pricebook_item_categories pic JOIN pricebook_categories c ON c.id = pic.category_id WHERE pic.item_id = p_item
    UNION ALL SELECT p.id, p.parent_id, p.name, cats.d + 1 FROM pricebook_categories p JOIN cats ON p.id = cats.parent_id WHERE cats.d < 8),
  txt AS (SELECT name::text AS name, -1 AS d FROM pricebook_items WHERE id = p_item UNION ALL SELECT name::text, d FROM cats)
  SELECT g.id FROM txt JOIN commission_groups g ON coalesce(g.keywords, '') <> '' AND txt.name ~* g.keywords
  ORDER BY txt.d, g.sort_order LIMIT 1
$f$;
CREATE OR REPLACE FUNCTION public._comm_group(p_item bigint)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM comm_item_group_cache c WHERE c.item_id = p_item)
              THEN (SELECT c.group_id FROM comm_item_group_cache c WHERE c.item_id = p_item)
              ELSE public._comm_group_live(p_item) END
$f$;
-- fill in the items used on invoices and proposals that aren't remembered yet (a few hundred at a time keeps it quick)
CREATE OR REPLACE FUNCTION public.refresh_comm_item_groups(p_max int DEFAULT 4000) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
DECLARE n int;
BEGIN
  IF public.current_staff_role() IS NULL AND current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN RETURN 0; END IF;
  INSERT INTO comm_item_group_cache (item_id, group_id)
  SELECT x.item_id, public._comm_group_live(x.item_id) FROM (
    SELECT DISTINCT item_id FROM (SELECT item_id FROM invoice_lines WHERE item_id IS NOT NULL UNION SELECT item_id FROM estimate_lines WHERE item_id IS NOT NULL) u
    WHERE NOT EXISTS (SELECT 1 FROM comm_item_group_cache c WHERE c.item_id = u.item_id) LIMIT p_max) x
  ON CONFLICT (item_id) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT; RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public._comm_group_live(bigint), public._comm_group(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.refresh_comm_item_groups(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refresh_comm_item_groups(int) TO authenticated;

-- forget when something it depends on changes
CREATE OR REPLACE FUNCTION public._comm_group_forget_all() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN DELETE FROM comm_item_group_cache; RETURN NULL; END $f$;
CREATE OR REPLACE FUNCTION public._comm_group_forget_item() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN DELETE FROM comm_item_group_cache WHERE item_id = (CASE WHEN TG_TABLE_NAME = 'pricebook_items' THEN OLD.id ELSE OLD.item_id END); END IF;
  IF TG_OP IN ('UPDATE', 'INSERT') THEN DELETE FROM comm_item_group_cache WHERE item_id = (CASE WHEN TG_TABLE_NAME = 'pricebook_items' THEN NEW.id ELSE NEW.item_id END); END IF;
  RETURN NULL;
END $f$;
DROP TRIGGER IF EXISTS comm_group_forget ON public.commission_groups;
CREATE TRIGGER comm_group_forget AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON public.commission_groups FOR EACH STATEMENT EXECUTE FUNCTION public._comm_group_forget_all();
DROP TRIGGER IF EXISTS comm_group_forget ON public.pricebook_categories;
CREATE TRIGGER comm_group_forget AFTER INSERT OR DELETE OR TRUNCATE OR UPDATE OF name, parent_id ON public.pricebook_categories FOR EACH STATEMENT EXECUTE FUNCTION public._comm_group_forget_all();
DROP TRIGGER IF EXISTS comm_group_forget ON public.pricebook_item_categories;
CREATE TRIGGER comm_group_forget AFTER INSERT OR UPDATE OR DELETE ON public.pricebook_item_categories FOR EACH ROW EXECUTE FUNCTION public._comm_group_forget_item();
DROP TRIGGER IF EXISTS comm_group_forget ON public.pricebook_items;
CREATE TRIGGER comm_group_forget AFTER UPDATE OF name OR DELETE ON public.pricebook_items FOR EACH ROW EXECUTE FUNCTION public._comm_group_forget_item();

-- indexes the per-row lookups lean on
CREATE INDEX IF NOT EXISTS invoices_job_id_idx ON public.invoices (job_id);
CREATE INDEX IF NOT EXISTS invoice_lines_invoice_id_idx ON public.invoice_lines (invoice_id);
CREATE INDEX IF NOT EXISTS estimate_lines_option_idx ON public.estimate_lines (estimate_option_id);
CREATE INDEX IF NOT EXISTS estimates_job_id_idx ON public.estimates (job_id);
CREATE INDEX IF NOT EXISTS visits_job_id_idx ON public.visits (job_id);
CREATE INDEX IF NOT EXISTS equipment_location_idx ON public.equipment (location_id);

SET LOCAL statement_timeout = '10min';
SELECT public.refresh_comm_item_groups(100000) AS items_remembered;
NOTIFY pgrst, 'reload schema';

-- Compare details: up to 10 lines (name + value) on each price book item, shown in a table when items are compared side by side.
-- Safe to run more than once.
ALTER TABLE public.pricebook_items ADD COLUMN IF NOT EXISTS compare_lines jsonb;

CREATE OR REPLACE FUNCTION public.pb_compare_get(p_ids bigint[])
RETURNS TABLE (id bigint, lines jsonb) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT i.id, coalesce(i.compare_lines, '[]'::jsonb) FROM pricebook_items i
  WHERE public.current_staff_role() IS NOT NULL AND i.id = ANY (p_ids)
$f$;

CREATE OR REPLACE FUNCTION public.pb_compare_labels()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT coalesce(jsonb_agg(l ORDER BY n DESC, l), '[]') FROM (
    SELECT btrim(x ->> 'label') AS l, count(*) AS n FROM pricebook_items i, jsonb_array_elements(coalesce(i.compare_lines, '[]')) x
    WHERE public.current_staff_role() IS NOT NULL AND btrim(coalesce(x ->> 'label', '')) <> '' GROUP BY 1 LIMIT 200) t
$f$;

CREATE OR REPLACE FUNCTION public.pb_compare_set(p_id bigint, p_lines jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
DECLARE v jsonb;
BEGIN
  IF NOT (public.has_permission('pricebook.edit') OR coalesce(public._is_owner(), false)) THEN RAISE EXCEPTION 'You can''t change the price book'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('label', left(btrim(coalesce(x ->> 'label', '')), 60), 'value', left(btrim(coalesce(x ->> 'value', '')), 120)) ORDER BY o), '[]')
    INTO v FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]' END) WITH ORDINALITY AS t(x, o)
    WHERE o <= 10 AND (btrim(coalesce(x ->> 'label', '')) <> '' OR btrim(coalesce(x ->> 'value', '')) <> '');
  UPDATE pricebook_items SET compare_lines = nullif(v, '[]'::jsonb), updated_at = now() WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That part no longer exists'; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('pricebook_items', p_id, 'update', public.current_app_user_id(), jsonb_build_object('compare_lines', v));
END $f$;

REVOKE EXECUTE ON FUNCTION public.pb_compare_get(bigint[]), public.pb_compare_labels(), public.pb_compare_set(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_compare_get(bigint[]), public.pb_compare_labels(), public.pb_compare_set(bigint, jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Compare details: an item with none of its own uses the details of another copy with the same code (SKU) or the same model.
-- Safe to run more than once.
CREATE OR REPLACE FUNCTION public.pb_compare_get(p_ids bigint[])
RETURNS TABLE (id bigint, lines jsonb) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT i.id, coalesce(nullif(i.compare_lines, '[]'::jsonb),
           (SELECT j.compare_lines FROM pricebook_items j
             WHERE j.id <> i.id AND nullif(j.compare_lines, '[]'::jsonb) IS NOT NULL
               AND ((nullif(btrim(i.sku), '') IS NOT NULL AND lower(btrim(j.sku)) = lower(btrim(i.sku)))
                 OR (nullif(btrim(i.model), '') IS NOT NULL AND lower(btrim(j.model)) = lower(btrim(i.model))))
             ORDER BY j.active DESC, j.updated_at DESC LIMIT 1),
           '[]'::jsonb)
  FROM pricebook_items i
  WHERE public.current_staff_role() IS NOT NULL AND i.id = ANY (p_ids)
$f$;
REVOKE EXECUTE ON FUNCTION public.pb_compare_get(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_compare_get(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

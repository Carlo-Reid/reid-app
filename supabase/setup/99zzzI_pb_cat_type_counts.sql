-- Price book: how many items (in use) each category has of each type, so the category list on the left
-- can show only the categories with Equipment / Services (Parts) / Materials when one of the quick buttons is on.
-- Safe to run more than once.
CREATE OR REPLACE FUNCTION public.pb_category_type_counts()
RETURNS TABLE (category_id bigint, item_type text, n bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT ic.category_id, p.item_type::text, count(*)
  FROM pricebook_item_categories ic JOIN pricebook_items p ON p.id = ic.item_id AND p.active
  WHERE public.current_staff_role() IS NOT NULL
  GROUP BY ic.category_id, p.item_type
$$;
REVOKE EXECUTE ON FUNCTION public.pb_category_type_counts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_category_type_counts() TO authenticated;

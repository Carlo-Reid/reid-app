-- Supplier invoices: each supplier's logo, shown on its button (and on its statement page). Dropped in, replaced or deleted in the app.
CREATE TABLE IF NOT EXISTS public.supplier_logos (
  supplier_id bigint PRIMARY KEY, image text NOT NULL, mime text NOT NULL DEFAULT 'image/png',
  updated_by bigint, updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.supplier_logos ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.supplier_logos_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(jsonb_build_object('supplier_id', supplier_id, 'image', image, 'mime', mime)) FROM supplier_logos), '[]'::jsonb) END $$;

-- p_image: the picture as base64 (no "data:" part); null deletes the logo
CREATE OR REPLACE FUNCTION public.supplier_logo_set(p_supplier bigint, p_image text, p_mime text DEFAULT 'image/png') RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier logos'; END IF;
  IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier) THEN RAISE EXCEPTION 'That supplier is gone'; END IF;
  IF p_image IS NULL OR btrim(p_image) = '' THEN DELETE FROM supplier_logos WHERE supplier_id = p_supplier;
  ELSE
    IF length(p_image) > 1500000 THEN RAISE EXCEPTION 'That picture is too big'; END IF;
    INSERT INTO supplier_logos (supplier_id, image, mime, updated_by, updated_at) VALUES (p_supplier, p_image, coalesce(p_mime, 'image/png'), public.current_app_user_id(), now())
    ON CONFLICT (supplier_id) DO UPDATE SET image = EXCLUDED.image, mime = EXCLUDED.mime, updated_by = EXCLUDED.updated_by, updated_at = now();
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_logos', p_supplier, CASE WHEN p_image IS NULL OR btrim(p_image) = '' THEN 'delete' ELSE 'update' END, public.current_app_user_id(), jsonb_build_object('supplier', p_supplier));
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_logos_list(), public.supplier_logo_set(bigint, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_logos_list(), public.supplier_logo_set(bigint, text, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

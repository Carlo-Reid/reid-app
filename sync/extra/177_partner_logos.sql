-- Partners: each partner's logo, shown on its card on the Partners page and at the top of its page. Dropped in, replaced or deleted in the app.
CREATE TABLE IF NOT EXISTS public.partner_logos (
  partner_id bigint PRIMARY KEY, image text NOT NULL, mime text NOT NULL DEFAULT 'image/png',
  updated_by bigint, updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.partner_logos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.partner_logos FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.partner_logos_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(jsonb_build_object('partner_id', partner_id, 'image', image, 'mime', mime)) FROM partner_logos), '[]'::jsonb) END $$;

-- p_image: the picture as base64 (no "data:" part); null deletes the logo
CREATE OR REPLACE FUNCTION public.partner_logo_set(p_partner bigint, p_image text, p_mime text DEFAULT 'image/png') RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'You don''t have permission to change partners'; END IF;
  IF NOT EXISTS (SELECT 1 FROM partners WHERE id = p_partner) THEN RAISE EXCEPTION 'That partner is gone'; END IF;
  IF p_image IS NULL OR btrim(p_image) = '' THEN DELETE FROM partner_logos WHERE partner_id = p_partner;
  ELSE
    IF length(p_image) > 1500000 THEN RAISE EXCEPTION 'That picture is too big'; END IF;
    INSERT INTO partner_logos (partner_id, image, mime, updated_by, updated_at) VALUES (p_partner, p_image, coalesce(p_mime, 'image/png'), public.current_app_user_id(), now())
    ON CONFLICT (partner_id) DO UPDATE SET image = EXCLUDED.image, mime = EXCLUDED.mime, updated_by = EXCLUDED.updated_by, updated_at = now();
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('partner_logos', p_partner, CASE WHEN p_image IS NULL OR btrim(p_image) = '' THEN 'delete' ELSE 'update' END, public.current_app_user_id(), jsonb_build_object('partner', p_partner));
END $function$;
REVOKE EXECUTE ON FUNCTION public.partner_logos_list(), public.partner_logo_set(bigint, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.partner_logos_list(), public.partner_logo_set(bigint, text, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

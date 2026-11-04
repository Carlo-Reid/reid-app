-- Partner logos: the list also gives each partner's name, so the logo can go on that partner's buttons anywhere in the app
CREATE OR REPLACE FUNCTION public.partner_logos_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(jsonb_build_object('partner_id', l.partner_id, 'name', p.name, 'image', l.image, 'mime', l.mime)) FROM partner_logos l LEFT JOIN partners p ON p.id = l.partner_id), '[]'::jsonb) END $$;
NOTIFY pgrst, 'reload schema';

-- Staff page: a picture for each person, shown on their button. Dropped in, replaced or deleted in the app (needs "Manage staff", or an owner).
CREATE TABLE IF NOT EXISTS public.staff_photos (
  app_user_id bigint PRIMARY KEY, image text NOT NULL, mime text NOT NULL DEFAULT 'image/jpeg',
  updated_by bigint, updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.staff_photos ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.staff_photos_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', p.app_user_id, 'employee_id', u.employee_id, 'image', p.image, 'mime', p.mime))
              FROM staff_photos p LEFT JOIN app_users u ON u.id = p.app_user_id), '[]'::jsonb) END $$;

-- p_image: the picture as base64 (no "data:" part); null deletes it
CREATE OR REPLACE FUNCTION public.staff_photo_set(p_user bigint, p_image text, p_mime text DEFAULT 'image/jpeg') RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (public.has_permission('staff.manage') OR coalesce(public._is_owner(), false)) THEN RAISE EXCEPTION 'You need "Manage staff" to change staff pictures'; END IF;
  IF NOT EXISTS (SELECT 1 FROM app_users WHERE id = p_user) THEN RAISE EXCEPTION 'That person is gone'; END IF;
  IF p_image IS NULL OR btrim(p_image) = '' THEN DELETE FROM staff_photos WHERE app_user_id = p_user;
  ELSE
    IF length(p_image) > 600000 THEN RAISE EXCEPTION 'That picture is too big'; END IF;
    INSERT INTO staff_photos (app_user_id, image, mime, updated_by, updated_at) VALUES (p_user, p_image, coalesce(p_mime, 'image/jpeg'), public.current_app_user_id(), now())
    ON CONFLICT (app_user_id) DO UPDATE SET image = EXCLUDED.image, mime = EXCLUDED.mime, updated_by = EXCLUDED.updated_by, updated_at = now();
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('staff_photos', p_user, CASE WHEN p_image IS NULL OR btrim(p_image) = '' THEN 'delete' ELSE 'update' END, public.current_app_user_id(), jsonb_build_object('user', p_user));
END $function$;
REVOKE EXECUTE ON FUNCTION public.staff_photos_list(), public.staff_photo_set(bigint, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_photos_list(), public.staff_photo_set(bigint, text, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

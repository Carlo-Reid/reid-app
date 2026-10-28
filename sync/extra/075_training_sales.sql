-- Owner-only switch on a sales person (shown to owners as "Training Sales"). The person never sees the name:
-- their app only learns it's in the "guided" mode, which changes what they see and can do.
CREATE TABLE IF NOT EXISTS public.staff_training (
  app_user_id bigint PRIMARY KEY,
  turned_on_by bigint,
  turned_on_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.staff_training ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.staff_training FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.staff_training_list() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('user', t.app_user_id, 'by', public._staff_name(t.turned_on_by), 'at', t.turned_on_at)) FROM staff_training t), '[]'::jsonb);
END $function$;

CREATE OR REPLACE FUNCTION public.set_staff_training(p_user bigint, p_on boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Owners only'; END IF;
  IF p_on THEN INSERT INTO staff_training (app_user_id, turned_on_by) VALUES (p_user, public.current_app_user_id()) ON CONFLICT (app_user_id) DO NOTHING;
  ELSE DELETE FROM staff_training WHERE app_user_id = p_user; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('app_users', p_user, 'update', public.current_app_user_id(), jsonb_build_object('guided', p_on));
END $function$;

-- for the person's own app: just "guided" or nothing
CREATE OR REPLACE FUNCTION public.my_ui_mode() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM staff_training WHERE app_user_id = public.current_app_user_id()) THEN 'guided' END
$function$;
REVOKE EXECUTE ON FUNCTION public.staff_training_list(), public.set_staff_training(bigint, boolean), public.my_ui_mode() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_training_list(), public.set_staff_training(bigint, boolean), public.my_ui_mode() TO authenticated;
NOTIFY pgrst, 'reload schema';

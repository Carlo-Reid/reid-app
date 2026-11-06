-- Techs start on the Classic colour look (Nov 6, 2026), once. Their text size stays; they can pick another look later and it sticks.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.st_sync_state WHERE endpoint = 'techs-classic-look') THEN RETURN; END IF;
  UPDATE public.app_users SET theme_prefs = jsonb_build_object('id', 'classic', 'custom', '{}'::jsonb, 'font', coalesce(theme_prefs ->> 'font', 'm'), 'pages', '{}'::jsonb, 'v', 2)
   WHERE role = 'technician';
  INSERT INTO public.st_sync_state (endpoint, continue_from, since, updated_at) VALUES ('techs-classic-look', NULL, now(), now());
END $$;

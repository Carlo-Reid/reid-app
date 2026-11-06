-- Techs start on the Classic colour look (Nov 6, 2026). Their text size stays; they can still pick another look later.
UPDATE public.app_users SET theme_prefs = jsonb_build_object('id', 'classic', 'custom', '{}'::jsonb, 'font', coalesce(theme_prefs ->> 'font', 'm'), 'pages', '{}'::jsonb, 'v', 2)
 WHERE role = 'technician';

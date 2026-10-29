-- "Online now": owners only show to other owners
SELECT public._patch_fn('check_in', 'WHERE u.active AND u.last_seen_at > now() - interval ''3 minutes''',
  'WHERE u.active AND u.last_seen_at > now() - interval ''3 minutes'' AND (u.id = v_me OR u.role::text <> ''owner'' OR public.current_staff_role() = ''owner'')');

-- Dispatch board: an owner whose tech record isn't the one tied to his login (George) still counts as an owner:
-- same name as an owner's login, or an owner login with no person tied to it whose email starts with his first name.
CREATE OR REPLACE FUNCTION public.dsp_staff_groups() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  WITH own AS (
    SELECT a.employee_id, lower(btrim(public._emp_name(a.employee_id))) AS nm, lower(split_part(a.login_email, '@', 1)) AS em
    FROM app_users a WHERE a.role = 'owner' AND a.active AND a.deleted_at IS NULL)
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', public._emp_name(e.id),
    'grp', CASE WHEN u.role = 'owner'
                 OR EXISTS (SELECT 1 FROM own o WHERE o.nm IS NOT NULL AND o.nm = lower(btrim(public._emp_name(e.id))))
                 OR EXISTS (SELECT 1 FROM own o WHERE o.employee_id IS NULL AND length(btrim(e.first_name)) >= 3 AND o.em LIKE lower(btrim(e.first_name)) || '%') THEN 'owner'
                WHEN u.role = 'sales' THEN 'sales' WHEN u.role IS NULL OR u.role = 'technician' THEN 'tech' ELSE 'office' END)), '[]'::jsonb) END
  FROM employees e LEFT JOIN LATERAL (SELECT role FROM app_users a WHERE a.employee_id = e.id AND a.active AND a.deleted_at IS NULL
                                      ORDER BY (a.role = 'owner') DESC, a.id LIMIT 1) u ON true
  WHERE e.active $$;
NOTIFY pgrst, 'reload schema';

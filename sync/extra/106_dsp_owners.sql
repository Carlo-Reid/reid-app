-- Dispatch board: owners are their own group (Carlo and George), always on the board, with their names.
CREATE OR REPLACE FUNCTION public.dsp_staff_groups() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', public._emp_name(e.id),
    'grp', CASE WHEN u.role = 'owner' THEN 'owner' WHEN u.role = 'sales' THEN 'sales' WHEN u.role IS NULL OR u.role = 'technician' THEN 'tech' ELSE 'office' END)), '[]'::jsonb) END
  FROM employees e LEFT JOIN LATERAL (SELECT role FROM app_users a WHERE a.employee_id = e.id AND a.active AND a.deleted_at IS NULL
                                      ORDER BY (a.role = 'owner') DESC, a.id LIMIT 1) u ON true
  WHERE e.active $$;
NOTIFY pgrst, 'reload schema';

-- Dispatch board: which group each person on the board belongs to, so the board can put Techs, Office and Sales apart.
-- Sales = a sales login; Office = any other office login (owner, office, dispatch…); Techs = technicians and anyone without a login.
CREATE OR REPLACE FUNCTION public.dsp_staff_groups() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce(jsonb_agg(jsonb_build_object('id', e.id,
    'grp', CASE WHEN u.role = 'sales' THEN 'sales' WHEN u.role IS NULL OR u.role = 'technician' THEN 'tech' ELSE 'office' END)), '[]'::jsonb) END
  FROM employees e LEFT JOIN LATERAL (SELECT role FROM app_users a WHERE a.employee_id = e.id AND a.active AND a.deleted_at IS NULL ORDER BY a.id LIMIT 1) u ON true
  WHERE e.active $$;
REVOKE EXECUTE ON FUNCTION public.dsp_staff_groups() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dsp_staff_groups() TO authenticated;
NOTIFY pgrst, 'reload schema';

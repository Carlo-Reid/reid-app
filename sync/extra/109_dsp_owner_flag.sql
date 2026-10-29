-- Dispatch board: only people added as owners show with the Owners: their record tied to an owner login, or a record marked
-- "owner on the dispatch board" (George's and Carlo's old tech records, marked once here). A new tech never lands there by his name.
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS board_owner boolean NOT NULL DEFAULT false;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM employees WHERE board_owner) THEN   -- once: the owners' other records, by first name, as they are today
    UPDATE employees e SET board_owner = true
    WHERE e.active AND EXISTS (SELECT 1 FROM app_users a WHERE a.role = 'owner' AND a.active AND a.deleted_at IS NULL AND a.employee_id IS NOT NULL
      AND length(btrim(e.first_name)) >= 3 AND lower(split_part(btrim(coalesce(public._emp_name(a.employee_id), '')), ' ', 1)) = lower(btrim(e.first_name)));
  END IF;
END $$;
CREATE OR REPLACE FUNCTION public.dsp_staff_groups() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', public._emp_name(e.id),
    'grp', CASE WHEN u.role = 'owner' OR e.board_owner THEN 'owner'
                WHEN u.role = 'sales' THEN 'sales' WHEN u.role IS NULL OR u.role = 'technician' THEN 'tech' ELSE 'office' END)), '[]'::jsonb) END
  FROM employees e LEFT JOIN LATERAL (SELECT role FROM app_users a WHERE a.employee_id = e.id AND a.active AND a.deleted_at IS NULL
                                      ORDER BY (a.role = 'owner') DESC, a.id LIMIT 1) u ON true
  WHERE e.active $$;
NOTIFY pgrst, 'reload schema';

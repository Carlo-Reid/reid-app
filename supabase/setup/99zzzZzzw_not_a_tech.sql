-- Staff page: take someone off the Technicians list (and put them back). Kept here, so ServiceTitan's nightly
-- "technician" flag doesn't put them back.
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS not_tech boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.tech_kinds()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public SET jit = off AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'name', public._emp_name(e.id), 'kind', e.tech_kind, 'not_tech', e.not_tech,
      'recent', EXISTS (SELECT 1 FROM visit_assignments va JOIN visits v ON v.id = va.visit_id WHERE va.employee_id = e.id AND v.scheduled_date > current_date - 120)
                OR EXISTS (SELECT 1 FROM app_users u WHERE u.employee_id = e.id AND u.active AND u.deleted_at IS NULL AND u.role = 'technician'))
      ORDER BY public._emp_name(e.id)), '[]'::jsonb) END
  FROM employees e WHERE e.active AND e.is_technician AND e.first_name NOT LIKE 'ZPast-%' AND public._emp_name(e.id) IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION public.set_not_tech(p_employee bigint, p_on boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.has_permission('staff.manage') OR public.current_staff_role() = 'owner') THEN RAISE EXCEPTION 'You need "Manage staff" to change this'; END IF;
  UPDATE employees SET not_tech = coalesce(p_on, false) WHERE id = p_employee;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('employees', p_employee, 'update', public.current_app_user_id(), jsonb_build_object('not_tech', coalesce(p_on, false)));
END $$;
REVOKE EXECUTE ON FUNCTION public.tech_kinds(), public.set_not_tech(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tech_kinds(), public.set_not_tech(bigint, boolean) TO authenticated;
NOTIFY pgrst, 'reload schema';

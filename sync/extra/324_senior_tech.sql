-- Carlo, Nov 19, 2026: "Allow senior techs to view all tech calls. Adam and Dave are Senior Techs add the setting to there profiles as
-- checked and all other except owners unchecked". One row for each senior tech. A senior tech can LOOK at every tech's day on Tech Calls
-- (my_day for another tech, and what is being installed on a call). It gives no other permission.
CREATE TABLE IF NOT EXISTS public.staff_senior_tech (app_user_id bigint PRIMARY KEY, set_by text, set_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.staff_senior_tech ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.staff_senior_tech FROM PUBLIC, anon, authenticated;

-- the first time only: Adam and Dave (by first name, technicians). After that the Staff page's tick box decides, so an untick stays.
CREATE TABLE IF NOT EXISTS public.staff_senior_seed (done boolean PRIMARY KEY);
ALTER TABLE public.staff_senior_seed ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.staff_senior_seed FROM PUBLIC, anon, authenticated;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.staff_senior_seed) THEN
    INSERT INTO public.staff_senior_tech (app_user_id, set_by)
      SELECT u.id, 'Carlo, Nov 19, 2026' FROM public.app_users u JOIN public.employees e ON e.id = u.employee_id
      WHERE u.role = 'technician' AND u.active AND u.deleted_at IS NULL AND lower(e.first_name) IN ('adam', 'dave')
    ON CONFLICT DO NOTHING;
    INSERT INTO public.staff_senior_seed VALUES (true);
  END IF;
END $$;

-- is the person signed in a senior tech?
CREATE OR REPLACE FUNCTION public.is_senior_tech() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT public.current_staff_role() = 'technician' AND EXISTS (SELECT 1 FROM staff_senior_tech WHERE app_user_id = public.current_app_user_id()) $f$;

-- Staff page: who is ticked
CREATE OR REPLACE FUNCTION public.staff_senior_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.has_permission('staff.manage') OR public.current_staff_role() = 'owner'
    THEN coalesce((SELECT jsonb_agg(app_user_id) FROM staff_senior_tech), '[]'::jsonb) ELSE '[]'::jsonb END $f$;

CREATE OR REPLACE FUNCTION public.staff_senior_set(p_user bigint, p_on boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (public.has_permission('staff.manage') OR public.current_staff_role() = 'owner') THEN RAISE EXCEPTION 'You need "Manage staff" to change this'; END IF;
  IF p_user IS NULL THEN RAISE EXCEPTION 'No person picked'; END IF;
  IF coalesce(p_on, false) THEN
    INSERT INTO staff_senior_tech (app_user_id, set_by) VALUES (p_user, auth.jwt() ->> 'email')
    ON CONFLICT (app_user_id) DO UPDATE SET set_by = EXCLUDED.set_by, set_at = now();
  ELSE DELETE FROM staff_senior_tech WHERE app_user_id = p_user; END IF;
END $function$;

REVOKE EXECUTE ON FUNCTION public.is_senior_tech(), public.staff_senior_list(), public.staff_senior_set(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_senior_tech(), public.staff_senior_list(), public.staff_senior_set(bigint, boolean) TO authenticated;

-- my_day (made by the sync's own schema on every run): a senior tech may look at another tech's day. Patched in place, once per run.
DO $$
DECLARE d text; a text := 'AND NOT (public.has_permission(''calls.dispatch'') OR public.has_permission(''calls.book'')) THEN';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'my_day' LIMIT 1;
  IF d IS NOT NULL AND position('is_senior_tech' IN d) = 0 AND position(a IN d) > 0 THEN
    EXECUTE replace(d, a, 'AND NOT (public.has_permission(''calls.dispatch'') OR public.has_permission(''calls.book'') OR public.is_senior_tech()) THEN');
  END IF;
END $$;

-- what is being installed on a call (323): a senior tech may read it for any call
CREATE OR REPLACE FUNCTION public.call_items(p_visit_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN NOT (public._install_ok(p_visit_id) OR public.is_senior_tech()) THEN NULL ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('name', p.name, 'sku', p.sku, 'model', p.model_number, 'type', p.item_type, 'qty', il.quantity)
                     ORDER BY (p.item_type = 'equipment') DESC, i.id, il.sequence, il.id)
    FROM visits v JOIN invoices i ON i.job_id = v.job_id JOIN invoice_lines il ON il.invoice_id = i.id JOIN pricebook_items p ON p.id = il.item_id
    WHERE v.id = p_visit_id AND i.status <> 'void' AND i.store_copy_of IS NULL AND i.deleted_at IS NULL
      AND p.item_type IN ('equipment', 'service', 'material') AND il.kit_parent_line_id IS NULL), '[]'::jsonb) END $function$;
NOTIFY pgrst, 'reload schema';

-- Carlo, Nov 19, 2026: on Tech Calls, "if its a partner add this is a Vista Customer with the partner logo". Which partner each call's job is from.
CREATE OR REPLACE FUNCTION public.call_partners(p_visits bigint[]) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('visit_id', v.id, 'partner_id', p.id, 'name', p.name))
    FROM visits v JOIN jobs j ON j.id = v.job_id JOIN partners p ON p.id = j.partner_id WHERE v.id = ANY (p_visits)), '[]'::jsonb) END $f$;
REVOKE EXECUTE ON FUNCTION public.call_partners(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.call_partners(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

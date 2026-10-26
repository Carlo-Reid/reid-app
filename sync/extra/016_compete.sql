-- "Why choose us": how we compare with up to 3 competitors on 10 points, shown under the side-by-side comparison on proposals.
-- Set on the Compare us page (owners). Safe to run more than once.
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS competitor_compare jsonb;

CREATE OR REPLACE FUNCTION public.compete_get()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE (SELECT competitor_compare FROM company_settings ORDER BY id LIMIT 1) END
$f$;

CREATE OR REPLACE FUNCTION public.compete_set(p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT (coalesce(public._is_owner(), false) OR public.has_permission('settings.manage')) THEN RAISE EXCEPTION 'Only owners can change this'; END IF;
  IF p IS NOT NULL AND (jsonb_typeof(p) <> 'object' OR length(p::text) > 30000) THEN RAISE EXCEPTION 'That is too much'; END IF;
  UPDATE company_settings SET competitor_compare = p WHERE id = (SELECT min(id) FROM company_settings);
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('company_settings', (SELECT min(id) FROM company_settings), 'update', public.current_app_user_id(), jsonb_build_object('competitor_compare', true));
END $f$;

REVOKE EXECUTE ON FUNCTION public.compete_get(), public.compete_set(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.compete_get(), public.compete_set(jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';

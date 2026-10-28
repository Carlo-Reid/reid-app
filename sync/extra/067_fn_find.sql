-- owner only: which functions mention some text (to find every place that adds up invoices)
CREATE OR REPLACE FUNCTION public._fn_find(p_text text) RETURNS text[] LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Owner only'; END IF;
  RETURN (SELECT array_agg(DISTINCT p.proname ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.prosrc ~* p_text);
END $function$;
REVOKE EXECUTE ON FUNCTION public._fn_find(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._fn_find(text) TO authenticated;
NOTIFY pgrst, 'reload schema';

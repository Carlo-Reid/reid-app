-- owner only: read a function's source (to change it safely from the app's repo)
CREATE OR REPLACE FUNCTION public._fn_src(p_name text) RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Owner only'; END IF;
  RETURN (SELECT string_agg(pg_get_functiondef(p.oid), E'\n-----\n') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = p_name);
END $function$;
REVOKE EXECUTE ON FUNCTION public._fn_src(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._fn_src(text) TO authenticated;
NOTIFY pgrst, 'reload schema';

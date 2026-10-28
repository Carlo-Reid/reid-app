-- owner only, for speed checks: the plan and timing of a SELECT
CREATE OR REPLACE FUNCTION public._explain(p_sql text) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE r text; o text := '';
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Owner only'; END IF;
  IF p_sql !~* '^\s*select\s' OR p_sql ~ ';' THEN RAISE EXCEPTION 'One SELECT only'; END IF;
  FOR r IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) ' || p_sql LOOP o := o || r || E'\n'; END LOOP;
  RETURN o;
END $function$;
REVOKE EXECUTE ON FUNCTION public._explain(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._explain(text) TO authenticated;
NOTIFY pgrst, 'reload schema';

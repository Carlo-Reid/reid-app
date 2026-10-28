-- owner only: a table's columns with defaults / generated formulas and its triggers
CREATE OR REPLACE FUNCTION public._tbl_cols(p_table text) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Owner only'; END IF;
  RETURN jsonb_build_object(
    'cols', (SELECT jsonb_agg(jsonb_build_object('c', column_name, 't', data_type, 'd', column_default, 'g', generation_expression) ORDER BY ordinal_position)
             FROM information_schema.columns WHERE table_schema = 'public' AND table_name = p_table),
    'triggers', (SELECT jsonb_agg(pg_get_triggerdef(t.oid)) FROM pg_trigger t WHERE t.tgrelid = ('public.' || p_table)::regclass AND NOT t.tgisinternal),
    'policies', (SELECT jsonb_agg(jsonb_build_object('name', polname, 'cmd', polcmd, 'using', pg_get_expr(polqual, polrelid))) FROM pg_policy WHERE polrelid = ('public.' || p_table)::regclass));
END $function$;
REVOKE EXECUTE ON FUNCTION public._tbl_cols(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._tbl_cols(text) TO authenticated;
NOTIFY pgrst, 'reload schema';

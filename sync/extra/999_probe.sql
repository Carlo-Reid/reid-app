DO $$ DECLARE r text; BEGIN
SELECT E'\n=====COLS\n' || (SELECT string_agg(column_name || ':' || data_type || coalesce(' GEN ' || generation_expression, '') || coalesce(' DEF ' || column_default, ''), E'\n' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='public' AND table_name='invoices')
 || E'\n=====LINECOLS\n' || (SELECT string_agg(column_name || ':' || data_type || coalesce(' DEF ' || column_default, ''), E'\n' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice_lines')
 || E'\n=====TRIGGERS\n' || (SELECT string_agg(tgrelid::regclass || ' ' || tgname || ' -> ' || tgfoid::regproc, E'\n') FROM pg_trigger WHERE tgrelid IN ('invoices'::regclass,'invoice_lines'::regclass,'payment_applications'::regclass) AND NOT tgisinternal)
 || E'\n=====USES_INV_FOR_EDIT\n' || (SELECT string_agg(DISTINCT p.proname, ' ') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prosrc ~ '_inv_for_edit')
 || E'\n=====INV_STID_CHECKS\n' || (SELECT string_agg(DISTINCT p.proname, ' ') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prosrc ~* 'invoice' AND p.prosrc ~* 'st_id IS (NOT )?NULL')
 || E'\n=====FN _inv_for_edit\n' || coalesce((SELECT string_agg(pg_get_functiondef(p.oid), E'\n---\n') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='_inv_for_edit'),'none')
 || E'\n=====FN recalc\n' || coalesce((SELECT string_agg(pg_get_functiondef(p.oid), E'\n---\n') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('recalc_invoice')),'none')
 || E'\n=====COUNTS\n' || (SELECT count(*) FILTER (WHERE st_id IS NOT NULL) || ' st, ' || count(*) FILTER (WHERE st_id IS NULL) || ' app' FROM invoices)
INTO r; RAISE EXCEPTION 'PROBE %', r; END $$;

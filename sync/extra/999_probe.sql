DO $$ DECLARE r text := ''; t record; n int; s record; BEGIN
FOR s IN SELECT * FROM suppliers WHERE name ~* 'breeze' ORDER BY id LOOP
  r := r || E'\n== supplier ' || s.id || ' ' || to_jsonb(s)::text || E'\n';
  FOR t IN SELECT c.table_name, c.column_name FROM information_schema.columns c JOIN information_schema.tables tb ON tb.table_name = c.table_name AND tb.table_schema = 'public' AND tb.table_type = 'BASE TABLE'
           WHERE c.table_schema = 'public' AND (c.column_name IN ('supplier_id', 'vendor_id') OR (c.table_name ~ 'supplier' AND c.column_name ~ 'supplier')) AND c.data_type = 'bigint' LOOP
    EXECUTE format('SELECT count(*) FROM %I WHERE %I = $1', t.table_name, t.column_name) INTO n USING s.id;
    IF n > 0 THEN r := r || t.table_name || '.' || t.column_name || '=' || n || '  '; END IF;
  END LOOP;
END LOOP;
r := r || E'\n== all supplier-id columns: ' || (SELECT string_agg(DISTINCT c.table_name || '.' || c.column_name, ' ') FROM information_schema.columns c JOIN information_schema.tables tb ON tb.table_name = c.table_name AND tb.table_schema='public' AND tb.table_type='BASE TABLE' WHERE c.table_schema='public' AND (c.column_name IN ('supplier_id','vendor_id') OR (c.table_name ~ 'supplier' AND c.column_name ~ 'supplier')) AND c.data_type='bigint');
r := r || E'\n== unique keys on supplier_id: ' || coalesce((SELECT string_agg(indexrelid::regclass || ': ' || pg_get_indexdef(indexrelid), E'\n') FROM pg_index i WHERE indisunique AND pg_get_indexdef(indexrelid) ~ 'supplier_id'), 'none');
r := r || E'\n== merge fn: ' || coalesce((SELECT string_agg(proname, ' ') FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname='public' AND proname ~* 'supplier.*(merge|combine)|merge.*supplier'), 'none');
RAISE EXCEPTION 'PROBE %', r; END $$;

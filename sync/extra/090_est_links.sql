-- What a proposal is tied to (so the customer page can show why it can't be deleted): every row in another table that points at
-- the proposal, one of its options, or one of its lines. Returns [{tbl, col, n, ids}] (ids: up to 20 of the linked rows).
CREATE OR REPLACE FUNCTION public.est_links(p_id bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE r record; v_out jsonb := '[]'; v_ids bigint[]; v_n int; v_keys bigint[];
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN NULL; END IF;
  FOR r IN SELECT c.conrelid::regclass AS tbl, a.attname AS col, c.confrelid::regclass AS ref FROM pg_constraint c
           JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
           WHERE c.contype = 'f' AND c.confrelid IN ('public.estimates'::regclass, 'public.estimate_options'::regclass, 'public.estimate_lines'::regclass)
             AND c.conrelid NOT IN ('public.estimates'::regclass, 'public.estimate_options'::regclass, 'public.estimate_lines'::regclass, 'public.install_holds'::regclass)
             AND NOT (c.conrelid = 'public.jobs'::regclass AND a.attname IN ('sold_estimate_id', 'from_estimate_id')) LOOP
    v_keys := CASE r.ref::text
      WHEN 'estimates' THEN ARRAY[p_id]
      WHEN 'estimate_options' THEN (SELECT array_agg(id) FROM estimate_options WHERE estimate_id = p_id)
      ELSE (SELECT array_agg(l.id) FROM estimate_lines l JOIN estimate_options o ON o.id = l.estimate_option_id WHERE o.estimate_id = p_id) END;
    CONTINUE WHEN v_keys IS NULL;
    BEGIN
      EXECUTE format('SELECT count(*), (array_agg(id ORDER BY id DESC))[1:20] FROM %s WHERE %I = ANY($1)', r.tbl, r.col) INTO v_n, v_ids USING v_keys;
    EXCEPTION WHEN undefined_column THEN
      EXECUTE format('SELECT count(*) FROM %s WHERE %I = ANY($1)', r.tbl, r.col) INTO v_n USING v_keys; v_ids := NULL;
    END;
    IF v_n > 0 THEN v_out := v_out || jsonb_build_object('tbl', r.tbl::text, 'col', r.col, 'n', v_n, 'ids', to_jsonb(v_ids)); END IF;
  END LOOP;
  RETURN v_out;
END $function$;
REVOKE EXECUTE ON FUNCTION public.est_links(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_links(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

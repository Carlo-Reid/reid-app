-- The reading rules built into the app are shown in each supplier's Rules box, where they can be turned on or off and their words and numbers changed
-- (Carlo, Nov 25, 2026: "add all the scans that happen to the pages to the supplier rules so I can adjust them if I need to with out your help").
-- opts = { "<rule key>": { "on": true|false, "<setting>": "words" | number } }. A key that is not there means the rule is on with its usual settings.
-- The rules and their usual settings are listed in the app (RD_OPTS in index.html); the database only keeps what was changed.
ALTER TABLE public.supplier_read_rules ADD COLUMN IF NOT EXISTS opts jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE OR REPLACE FUNCTION public.supplier_rules_get(p_supplier bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN NOT (public._sinv_can_edit() OR public._can_see_costs()) THEN '{}'::jsonb ELSE jsonb_build_object('can_edit', public._sinv_can_edit(),
    'by', coalesce((SELECT jsonb_object_agg(r.supplier_id::text, jsonb_build_object('rules', r.rules, 'notes', coalesce(r.notes, ''), 'opts', coalesce(r.opts, '{}'::jsonb), 'at', r.updated_at))
                    FROM supplier_read_rules r WHERE p_supplier IS NULL OR r.supplier_id = p_supplier), '{}'::jsonb)) END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_rules_get(bigint) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.supplier_rules_get(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.supplier_read_opts_set(p_supplier bigint, p_opts jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v jsonb := coalesce(p_opts, '{}'::jsonb); old jsonb;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier) THEN RAISE EXCEPTION 'That supplier is gone'; END IF;
  IF jsonb_typeof(v) <> 'object' THEN RAISE EXCEPTION 'The settings are not readable'; END IF;
  IF length(v::text) > 20000 THEN RAISE EXCEPTION 'The settings are too long'; END IF;
  SELECT opts INTO old FROM supplier_read_rules WHERE supplier_id = p_supplier;
  INSERT INTO supplier_read_rules (supplier_id, opts, updated_by, updated_at) VALUES (p_supplier, v, public.current_app_user_id(), now())
  ON CONFLICT (supplier_id) DO UPDATE SET opts = EXCLUDED.opts, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('supplier_read_rules', p_supplier, 'update', public.current_app_user_id(), jsonb_build_object('opts', old), jsonb_build_object('opts', v));
  RETURN jsonb_build_object('opts', v);
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_read_opts_set(bigint, jsonb) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.supplier_read_opts_set(bigint, jsonb) TO authenticated;

-- "A line number is never a part number" (337) follows the supplier's setting: off, or how many digits at most
CREATE OR REPLACE FUNCTION public._rd_line_no(p text, p_sid bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN coalesce(o->'lineno'->>'on', 'true') = 'false' THEN false
    ELSE coalesce(btrim(p), '') ~ ('^[0-9]{1,' || greatest(1, least(6, coalesce(CASE WHEN o->'lineno'->>'n' ~ '^\d+$' THEN (o->'lineno'->>'n')::int END, 3))) || '}$') END
  FROM (SELECT coalesce((SELECT opts FROM supplier_read_rules WHERE supplier_id = p_sid), '{}'::jsonb) AS o) z $$;

DO $do$ DECLARE d text; BEGIN
  SELECT pg_get_functiondef('public.import_supplier_lines(text, text, date, jsonb)'::regprocedure) INTO d;
  IF position('ln := public._is_line_no(c);' IN d) > 0 THEN EXECUTE replace(d, 'ln := public._is_line_no(c);', 'ln := public._rd_line_no(c, v_sid);'); END IF;
END $do$;

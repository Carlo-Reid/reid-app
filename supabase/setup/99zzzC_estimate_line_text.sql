-- =====================================================================
-- Estimates: the text under each item (its description from the price book) can be changed on the estimate.
-- The change is kept on that estimate line only (long_desc); the price book isn't touched. Empty = the price book's text.
-- Safe to run more than once.
-- =====================================================================
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'estimate_lines' AND column_name = 'long_desc') THEN
    ALTER TABLE public.estimate_lines ADD COLUMN long_desc text;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.est_save(p_id bigint, p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e estimates; o jsonb; ln jsonb; v_opt bigint; n int := 0; k int;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT * INTO e FROM estimates WHERE id = p_id; IF e.id IS NULL THEN RAISE EXCEPTION 'That estimate no longer exists'; END IF;
  IF e.status IN ('accepted', 'lost', 'declined', 'expired') THEN RAISE EXCEPTION 'This estimate is closed and can''t be changed'; END IF;
  IF jsonb_array_length(coalesce(p -> 'options', '[]')) > 3 THEN RAISE EXCEPTION 'Up to 3 options'; END IF;
  DELETE FROM estimate_lines WHERE estimate_option_id IN (SELECT id FROM estimate_options WHERE estimate_id = p_id);
  DELETE FROM estimate_options WHERE estimate_id = p_id;
  FOR o IN SELECT * FROM jsonb_array_elements(coalesce(p -> 'options', '[]')) LOOP
    n := n + 1;
    INSERT INTO estimate_options (estimate_id, sequence, name, description, is_recommended)
    VALUES (p_id, n, coalesce(nullif(btrim(o ->> 'name'), ''), 'Option ' || n), nullif(btrim(o ->> 'description'), ''), coalesce((o ->> 'recommended')::boolean, false))
    RETURNING id INTO v_opt;
    k := 0;
    FOR ln IN SELECT * FROM jsonb_array_elements(coalesce(o -> 'lines', '[]')) LOOP
      k := k + 1;
      INSERT INTO estimate_lines (estimate_option_id, sequence, item_id, description, quantity, unit_price, unit_cost, est_labour_hours, taxable, kit_skip, long_desc)
      SELECT v_opt, k, i.id, coalesce(nullif(btrim(ln ->> 'description'), ''), i.name, 'Item'), coalesce((ln ->> 'qty')::numeric, 1),
             coalesce((ln ->> 'price')::numeric, i.unit_price, 0), coalesce(i.unit_cost, 0), i.est_labour_hours, coalesce(i.taxable, true),
             CASE WHEN jsonb_typeof(ln -> 'skip') = 'array' AND jsonb_array_length(ln -> 'skip') > 0
                  THEN ARRAY(SELECT x::bigint FROM jsonb_array_elements_text(ln -> 'skip') x WHERE x ~ '^[0-9]+$') END,
             nullif(btrim(left(coalesce(ln ->> 'ldesc', ''), 20000)), '')
      FROM (SELECT 1) one LEFT JOIN pricebook_items i ON i.id = nullif(ln ->> 'item_id', '')::bigint;
    END LOOP;
  END LOOP;
  UPDATE estimates SET status = CASE WHEN p ? 'sent' AND (p ->> 'sent')::boolean THEN 'sent' ELSE status END,
         sent_at = CASE WHEN p ? 'sent' AND (p ->> 'sent')::boolean AND sent_at IS NULL THEN now() ELSE sent_at END, updated_at = now() WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('estimates', p_id, 'update', public.current_app_user_id(), jsonb_build_object('options', n));
END $$;
REVOKE EXECUTE ON FUNCTION public.est_save(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_save(bigint, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';

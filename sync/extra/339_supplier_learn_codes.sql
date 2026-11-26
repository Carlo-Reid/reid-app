-- 339: what a supplier's paper teaches the app (Carlo, Nov 25, 2026, taught on Trent Metal ship ticket S1609163.001)
-- (1) A line's code is the supplier's own part number (Trent's 10897). When that number is not yet tied to an item of ours for that
--     supplier, the line's words are looked at for our item number or model (AV40N): when exactly one item of ours has it, the
--     supplier's part number is saved on that item for that supplier (supplier_items.supplier_sku), so the next paper matches by itself.
--     Trent's two accounts (8 main, 63 water heaters) share their part numbers, so both get it. It never changes a part number already there.
-- (2) A serial number read on a supplier invoice line (lines[].serial) is found by "Find anything by its number".

CREATE OR REPLACE FUNCTION public._sinv_learn_codes(p_id bigint) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE i supplier_invoices; x jsonb; v_code text; v_item bigint; v_n int; v_sup bigint; v_done int := 0; v_sups bigint[];
BEGIN
  SELECT * INTO i FROM supplier_invoices WHERE id = p_id;
  IF i.id IS NULL OR i.supplier_id IS NULL OR jsonb_typeof(i.lines) IS DISTINCT FROM 'array' THEN RETURN 0; END IF;
  v_sups := CASE WHEN i.supplier_id IN (8, 63) THEN ARRAY[8, 63]::bigint[] ELSE ARRAY[i.supplier_id] END;
  FOR x IN SELECT * FROM jsonb_array_elements(i.lines) LOOP
    v_code := upper(btrim(coalesce(x ->> 'code', '')));
    CONTINUE WHEN length(v_code) < 3 OR v_code ~ '^\d{1,3}$' OR coalesce((x ->> 'by_hand')::boolean, false);
    CONTINUE WHEN EXISTS (SELECT 1 FROM supplier_items si WHERE si.supplier_id = i.supplier_id AND upper(btrim(si.supplier_sku)) = v_code);
    SELECT min(p.id), count(DISTINCT p.id) INTO v_item, v_n
      FROM (SELECT DISTINCT upper(t[1]) tok FROM regexp_matches(coalesce(x ->> 'description', ''), '([A-Za-z0-9][A-Za-z0-9\-/]{2,})', 'g') t) w
      JOIN pricebook_items p ON coalesce(p.active, true) AND NOT coalesce(p.pending_new, false)
        AND (upper(regexp_replace(coalesce(p.sku, ''), '[^A-Za-z0-9]', '', 'g')) = regexp_replace(w.tok, '[^A-Z0-9]', '', 'g')
          OR upper(regexp_replace(coalesce(p.model_number, ''), '[^A-Za-z0-9]', '', 'g')) = regexp_replace(w.tok, '[^A-Z0-9]', '', 'g'))
      WHERE w.tok ~ '[A-Z]' AND w.tok ~ '\d' AND length(regexp_replace(w.tok, '[^A-Z0-9]', '', 'g')) >= 4 AND regexp_replace(w.tok, '[^A-Z0-9]', '', 'g') <> v_code;
    CONTINUE WHEN v_n IS DISTINCT FROM 1;
    FOREACH v_sup IN ARRAY v_sups LOOP
      CONTINUE WHEN EXISTS (SELECT 1 FROM supplier_items si WHERE si.supplier_id = v_sup AND upper(btrim(si.supplier_sku)) = v_code);
      INSERT INTO supplier_items (supplier_id, item_id, supplier_sku, note)
      VALUES (v_sup, v_item, v_code, 'Learned from supplier invoice ' || coalesce(i.supplier_invoice_number, i.id::text) || ' (matched by the words on the line)')
      ON CONFLICT (supplier_id, item_id) DO UPDATE SET supplier_sku = EXCLUDED.supplier_sku, note = EXCLUDED.note, updated_at = now()
        WHERE nullif(btrim(supplier_items.supplier_sku), '') IS NULL;
      IF FOUND THEN v_done := v_done + 1;
        INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
        VALUES ('supplier_items', v_item, 'update', public.current_app_user_id(), jsonb_build_object('supplier', v_sup, 'supplier_sku', v_code, 'learned_from', i.id));
      END IF;
    END LOOP;
  END LOOP;
  RETURN v_done;
END $$;

CREATE OR REPLACE FUNCTION public._sinv_learn_trg() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NEW.lines IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.lines IS DISTINCT FROM OLD.lines) THEN
    BEGIN PERFORM public._sinv_learn_codes(NEW.id); EXCEPTION WHEN OTHERS THEN NULL; END;   -- never stops a save
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_sinv_learn ON supplier_invoices;
CREATE TRIGGER trg_sinv_learn AFTER INSERT OR UPDATE OF lines ON supplier_invoices FOR EACH ROW EXECUTE FUNCTION public._sinv_learn_trg();

-- (2) serial numbers on supplier invoice lines in find_number (patched in place, once)
DO $$
DECLARE d text; a text := '    UNION ALL SELECT ''mail'', sm.id';
BEGIN
  SELECT pg_get_functiondef('public.find_number(text)'::regprocedure) INTO d;
  IF d IS NULL OR position('Serial on supplier invoice' in d) > 0 OR position(a in d) = 0 THEN RETURN; END IF;
  d := replace(d, a, '    UNION ALL SELECT ''sinv'', si.id, NULL, ''Supplier invoice '' || si.supplier_invoice_number,
           ''Serial on supplier invoice: '' || (x ->> ''serial'') || '' · '' || coalesce((SELECT btrim(name) FROM suppliers WHERE id = si.supplier_id), '''') || '' · '' || left(coalesce(x ->> ''description'', ''''), 60),
           si.invoice_date, si.total, upper(x ->> ''serial'') = upper(q)
      FROM supplier_invoices si CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(si.lines) = ''array'' THEN si.lines ELSE ''[]''::jsonb END) x
      WHERE cost AND length(k) >= 4 AND (x ->> ''serial'') ILIKE ''%'' || q || ''%''
' || a);
  EXECUTE d;
END $$;

-- Auto update: find a paper's part in our price book by its item number (Carlo, Nov 25, 2026:
-- "on the auto update use the item number to find and attach it to an item in our system").
-- p_code = the part number printed on the supplier's paper. It is compared with our item number (sku),
-- the model number and every supplier's own part number, with marks taken out and look-alike letters
-- (O 0, I L 1, S 5, B 8, Z 2) counted the same. p_q = words typed in the search box (every kind of item,
-- parts too, in use or retired). Read only; people who see costs.
CREATE OR REPLACE FUNCTION public._pn_norm(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT translate(regexp_replace(upper(coalesce(t, '')), '[^A-Z0-9]', '', 'g'), 'OILSBZ', '011582')
$$;

CREATE OR REPLACE FUNCTION public.supplier_part_find(p_code text, p_supplier text DEFAULT NULL, p_q text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE c text := public._pn_norm(p_code); q text := btrim(coalesce(p_q, '')); sid bigint;
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN '[]'::jsonb; END IF;
  BEGIN sid := public._supplier_by_name(p_supplier); EXCEPTION WHEN others THEN sid := NULL; END;
  IF q <> '' THEN
    IF length(q) < 2 THEN RETURN '[]'::jsonb; END IF;
    RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.r, x.active DESC, x.name), '[]')
      FROM (SELECT p.id, p.name, p.sku AS code, p.model_number AS model, p.item_type AS type, p.active,
                   CASE WHEN upper(p.sku) = upper(q) OR upper(p.model_number) = upper(q) THEN 0 WHEN p.name ILIKE q || '%' THEN 1 ELSE 2 END r
            FROM pricebook_items p
            WHERE NOT coalesce(p.pending_new, false)
              AND (SELECT bool_and(concat_ws(' ', p.name, p.sku, p.model_number, p.manufacturer,
                     (SELECT string_agg(si.supplier_sku, ' ') FROM supplier_items si WHERE si.item_id = p.id)) ILIKE '%' || w || '%')
                   FROM regexp_split_to_table(q, '\s+') w)
            ORDER BY r, p.active DESC, p.name LIMIT 25) x);
  END IF;
  IF length(c) < 3 THEN RETURN '[]'::jsonb; END IF;
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.r, x.active DESC, x.name), '[]')
    FROM (SELECT p.id, p.name, p.sku AS code, p.model_number AS model, p.item_type AS type, p.active,
                 min(m.r) r, (array_agg(m.how ORDER BY m.r))[1] how
          FROM (
            SELECT si.item_id id, CASE WHEN si.supplier_id = sid THEN 0 ELSE 1 END r,
                   CASE WHEN si.supplier_id = sid THEN 'their part number' ELSE 'another supplier''s part number' END how
              FROM supplier_items si WHERE public._pn_norm(si.supplier_sku) = c
            UNION ALL SELECT p.id, 1, 'our item number' FROM pricebook_items p WHERE public._pn_norm(p.sku) = c
            UNION ALL SELECT p.id, 1, 'the model number' FROM pricebook_items p WHERE public._pn_norm(p.model_number) = c
            UNION ALL SELECT p.id, 2, 'the item number is in its name' FROM pricebook_items p
              WHERE length(c) >= 5 AND public._pn_norm(p.name) LIKE '%' || c || '%'
          ) m JOIN pricebook_items p ON p.id = m.id
          WHERE NOT coalesce(p.pending_new, false)
          GROUP BY p.id ORDER BY min(m.r), p.active DESC, p.name LIMIT 6) x);
END $$;
GRANT EXECUTE ON FUNCTION public.supplier_part_find(text, text, text) TO authenticated;

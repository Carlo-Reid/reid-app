-- Supplier invoices, Rules: one saved example for each kind of a supplier's papers (Carlo, Nov 24, 2026: "there should only be one set of rules and
-- examples that all months follow… it should always refer to the same examples for all documents for all months. also there are 5 documents that need
-- to be learned. I will load and label them one at a time"). Before this the Rules box showed the newest invoice of whatever month was on the screen.
-- An example = the pages of one paper (JPEG, base64), kept for the supplier and the kind of paper. It only changes when a person loads another one.
CREATE TABLE IF NOT EXISTS public.supplier_rule_examples (
  supplier_id bigint NOT NULL,
  form text NOT NULL,                              -- the kind of paper: 'Invoice', 'Packing slip / Sales order', 'Statement'…
  pages jsonb NOT NULL DEFAULT '[]'::jsonb,        -- ["<base64 jpeg>", …], page 1 first
  src text,                                        -- where it came from, in plain words (a file name, or "their invoice C399102")
  updated_by bigint, updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (supplier_id, form));
ALTER TABLE public.supplier_rule_examples ENABLE ROW LEVEL SECURITY;

-- the list, with no pictures: [{form, src, n, at}]
CREATE OR REPLACE FUNCTION public.supplier_rule_examples(p_supplier bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN NOT (public._sinv_can_edit() OR public._can_see_costs()) THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(jsonb_build_object('form', e.form, 'src', coalesce(e.src, ''), 'n', jsonb_array_length(e.pages), 'at', e.updated_at) ORDER BY e.updated_at)
              FROM supplier_rule_examples e WHERE e.supplier_id = p_supplier), '[]'::jsonb) END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_rule_examples(bigint) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.supplier_rule_examples(bigint) TO authenticated;

-- one page of an example (1 = the first)
CREATE OR REPLACE FUNCTION public.supplier_rule_example_page(p_supplier bigint, p_form text, p_page int DEFAULT 1) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN NOT (public._sinv_can_edit() OR public._can_see_costs()) THEN NULL ELSE
    (SELECT e.pages->>(greatest(coalesce(p_page, 1), 1) - 1) FROM supplier_rule_examples e WHERE e.supplier_id = p_supplier AND e.form = p_form) END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_rule_example_page(bigint, text, int) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.supplier_rule_example_page(bigint, text, int) TO authenticated;

-- save one kind's example (its pages replace the ones on file)
CREATE OR REPLACE FUNCTION public.supplier_rule_example_set(p_supplier bigint, p_form text, p_pages jsonb, p_src text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE f text := left(btrim(coalesce(p_form, '')), 40); n int;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier) THEN RAISE EXCEPTION 'That supplier is gone'; END IF;
  IF f = '' THEN RAISE EXCEPTION 'Give this kind of paper a name'; END IF;
  IF jsonb_typeof(coalesce(p_pages, 'null'::jsonb)) <> 'array' THEN RAISE EXCEPTION 'The example has no pages'; END IF;
  n := jsonb_array_length(p_pages);
  IF n < 1 OR n > 8 THEN RAISE EXCEPTION 'An example is 1 to 8 pages'; END IF;
  IF length(p_pages::text) > 6000000 THEN RAISE EXCEPTION 'That example is too big. Use fewer pages.'; END IF;
  IF (SELECT count(*) FROM supplier_rule_examples WHERE supplier_id = p_supplier AND form <> f) >= 12 THEN RAISE EXCEPTION 'That is too many kinds of paper (12 at most)'; END IF;
  INSERT INTO supplier_rule_examples (supplier_id, form, pages, src, updated_by, updated_at)
  VALUES (p_supplier, f, p_pages, nullif(left(btrim(coalesce(p_src, '')), 200), ''), public.current_app_user_id(), now())
  ON CONFLICT (supplier_id, form) DO UPDATE SET pages = EXCLUDED.pages, src = EXCLUDED.src, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_rule_examples', p_supplier, 'update', public.current_app_user_id(), jsonb_build_object('form', f, 'pages', n, 'src', p_src));
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_rule_example_set(bigint, text, jsonb, text) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.supplier_rule_example_set(bigint, text, jsonb, text) TO authenticated;

-- a kind of paper was renamed or removed in the Rules box: p_renames = {"old name": "new name"}, p_keep = every kind that is left
CREATE OR REPLACE FUNCTION public.supplier_rule_examples_tidy(p_supplier bigint, p_renames jsonb, p_keep text[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE k text; v text; gone text[];
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  FOR k, v IN SELECT key, left(btrim(value), 40) FROM jsonb_each_text(coalesce(p_renames, '{}'::jsonb)) LOOP
    IF v <> '' AND v <> k THEN
      DELETE FROM supplier_rule_examples WHERE supplier_id = p_supplier AND form = v;
      UPDATE supplier_rule_examples SET form = v, updated_at = now() WHERE supplier_id = p_supplier AND form = k;
    END IF;
  END LOOP;
  SELECT array_agg(form) INTO gone FROM supplier_rule_examples WHERE supplier_id = p_supplier AND NOT (form = ANY (coalesce(p_keep, ARRAY[]::text[])));
  IF gone IS NOT NULL THEN
    DELETE FROM supplier_rule_examples WHERE supplier_id = p_supplier AND form = ANY (gone);
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
    VALUES ('supplier_rule_examples', p_supplier, 'delete', public.current_app_user_id(), jsonb_build_object('forms', gone));
  END IF;
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_rule_examples_tidy(bigint, jsonb, text[]) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.supplier_rule_examples_tidy(bigint, jsonb, text[]) TO authenticated;

-- Boone's examples (Carlo gave the five papers in the chat on Nov 24, 2026; each one is already on file, so its pages are copied from there).
-- Only put in when Boone has no example of that kind, so one a person loads in the app stays.
INSERT INTO public.supplier_rule_examples (supplier_id, form, pages, src)
SELECT i.supplier_id, x.form, (SELECT jsonb_agg(p.image ORDER BY coalesce(p.ord, p.page_no), p.id) FROM supplier_doc_pages p WHERE p.supplier_invoice_id = i.id AND p.image IS NOT NULL), x.src
FROM (VALUES ('C399102', 'Invoice', 'their invoice C399102'),
             ('C333818', 'Packing slip / Sales order', 'their Sales order / Packing slip C333818'),
             ('C384650', 'Sales order / Pick ticket', 'their Sales order / Pick ticket C384650'),
             ('C367971', 'Credit memo', 'their credit memo C367971'),
             ('C339091', 'Customer return', 'their Customer return (pending ticket) C339091')) x(num, form, src)
JOIN public.suppliers s ON s.id = 1 AND s.name ILIKE 'Boone%'
JOIN public.supplier_invoices i ON i.supplier_id = s.id AND i.supplier_invoice_number = x.num
WHERE EXISTS (SELECT 1 FROM supplier_doc_pages p WHERE p.supplier_invoice_id = i.id AND p.image IS NOT NULL)
ON CONFLICT (supplier_id, form) DO NOTHING;

INSERT INTO public.supplier_rule_examples (supplier_id, form, pages, src)
SELECT st.supplier_id, 'Statement', (SELECT jsonb_agg(p.image ORDER BY p.page_no, p.id) FROM supplier_doc_pages p WHERE p.statement_id = st.id AND p.supplier_invoice_id IS NULL AND p.image IS NOT NULL), 'their statement of Sept 30, 2026'
FROM public.supplier_statements st JOIN public.suppliers s ON s.id = st.supplier_id AND s.id = 1 AND s.name ILIKE 'Boone%'
WHERE st.statement_date = DATE '2026-09-30' AND EXISTS (SELECT 1 FROM supplier_doc_pages p WHERE p.statement_id = st.id AND p.supplier_invoice_id IS NULL AND p.image IS NOT NULL)
ORDER BY st.id LIMIT 1
ON CONFLICT (supplier_id, form) DO NOTHING;

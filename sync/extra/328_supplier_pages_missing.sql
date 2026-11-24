-- Supplier invoices: which pages of a supplier's paper are missing (Carlo, Nov 24, 2026: "can it say missing 2 of 5 pages").
-- The browser reads each page once (the printed page number, the item line numbers, the word CONTINUED) and works it out;
-- the answer is kept here for everyone, with a mark of the pages it was worked out from, so it is dropped when a page is added or removed.
CREATE TABLE IF NOT EXISTS public.supplier_invoice_pages_check (
  invoice_id bigint PRIMARY KEY, res jsonb NOT NULL, sig text NOT NULL, at timestamptz NOT NULL DEFAULT now(), by_user bigint);
ALTER TABLE public.supplier_invoice_pages_check ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public._sinv_pages_sig(p_invoice bigint) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT count(*)::text || ':' || coalesce(max(id), 0)::text || ':' || coalesce(sum(id), 0)::text FROM supplier_doc_pages WHERE supplier_invoice_id = p_invoice;
$$;
REVOKE EXECUTE ON FUNCTION public._sinv_pages_sig(bigint) FROM PUBLIC, anon, authenticated;

-- keep what was read on the pages (only where words are sent) and the answer
CREATE OR REPLACE FUNCTION public.supplier_invoice_pages_seen(p_invoice bigint, p jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE h jsonb;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF NOT EXISTS (SELECT 1 FROM supplier_invoices WHERE id = p_invoice) THEN RAISE EXCEPTION 'That supplier invoice is not there'; END IF;
  FOR h IN SELECT * FROM jsonb_array_elements(coalesce(p->'have', '[]'::jsonb)) LOOP
    UPDATE supplier_doc_pages d SET printed_no = nullif(h->>'no', '')::int, first_line = nullif(h->>'line', '')::int,
           words = coalesce(left(h->>'words', 8000), d.words)
     WHERE d.id = (h->>'id')::bigint AND d.supplier_invoice_id = p_invoice;
  END LOOP;
  IF jsonb_typeof(p->'res') = 'object' THEN
    INSERT INTO supplier_invoice_pages_check AS c (invoice_id, res, sig, at, by_user)
    VALUES (p_invoice, p->'res', public._sinv_pages_sig(p_invoice), now(), public.current_app_user_id())
    ON CONFLICT (invoice_id) DO UPDATE SET res = excluded.res, sig = excluded.sig, at = excluded.at, by_user = excluded.by_user WHERE c.invoice_id = p_invoice;
  END IF;
  RETURN p->'res';
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_invoice_pages_seen(bigint, jsonb) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.supplier_invoice_pages_seen(bigint, jsonb) TO authenticated;

-- the kept answers for a list of supplier invoices: { "<id>": answer }, only where the pages are still the ones it was worked out from
CREATE OR REPLACE FUNCTION public.sinv_pages_check(p_ids bigint[])
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  RETURN coalesce((SELECT jsonb_object_agg(c.invoice_id::text, c.res) FROM supplier_invoice_pages_check c
                    WHERE c.invoice_id = ANY (p_ids[1:3000]) AND c.sig = public._sinv_pages_sig(c.invoice_id)), '{}'::jsonb);
END $function$;
REVOKE EXECUTE ON FUNCTION public.sinv_pages_check(bigint[]) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.sinv_pages_check(bigint[]) TO authenticated;

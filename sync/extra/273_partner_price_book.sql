-- Each partner can have its own price book: on a partner's job, the invoice's price book search only offers that book's items
-- (Carlo, Nov 12, 2026: "when a partner is picked then have the Price book option you can pick only come from that book … I made one called vista,
-- connect it to vista for me and have a way for me to do this for partners in the future"). Set on the Price books page (owners).
ALTER TABLE public.partners ADD COLUMN IF NOT EXISTS price_book_id bigint REFERENCES public.price_books(id) ON DELETE SET NULL;

-- the book a search runs as: a partner's book (set only by inv_item_search_book below) comes first
CREATE OR REPLACE FUNCTION public._my_book()
 RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE
    WHEN coalesce(current_setting('app.pb_partner_book', true), '') NOT IN ('', '0') THEN current_setting('app.pb_partner_book', true)::bigint
    WHEN current_setting('app.pb_any_item', true) = 'on' THEN NULL
    WHEN coalesce(current_setting('app.pb_book', true), '') <> '' AND public._pb_full() THEN nullif(current_setting('app.pb_book', true), '0')::bigint
    ELSE (SELECT price_book_id FROM app_users WHERE id = public.current_app_user_id()) END
$function$;

-- the partner's price book for this invoice's job (null when it is not a partner's job, or the partner has no book)
CREATE OR REPLACE FUNCTION public.inv_price_book(p_invoice bigint)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE
    (SELECT jsonb_build_object('book', b.id, 'name', b.name, 'partner', p.id, 'partner_name', p.name)
       FROM invoices i JOIN jobs j ON j.id = i.job_id JOIN partners p ON p.id = coalesce(j.partner_id, i.bill_to_partner_id)
       JOIN price_books b ON b.id = p.price_book_id
      WHERE i.id = p_invoice) END
$function$;

-- the invoice's price book search: only the partner's book on a partner's job; otherwise every item, as inv_item_search. Empty words = the whole book.
CREATE OR REPLACE FUNCTION public.inv_item_search_book(p_invoice bigint, p_search text, p_limit integer DEFAULT 12)
 RETURNS SETOF jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE bk bigint;
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN; END IF;
  SELECT (public.inv_price_book(p_invoice) ->> 'book')::bigint INTO bk;
  PERFORM set_config('app.pb_any_item', 'on', true);
  PERFORM set_config('app.pb_partner_book', coalesce(bk, 0)::text, true);
  RETURN QUERY SELECT to_jsonb(x) FROM public.pb_list(nullif(trim(coalesce(p_search, '')), ''), 'all', true, NULL, NULL, least(coalesce(p_limit, 12), 200)) x;
  PERFORM set_config('app.pb_partner_book', '', true);
  PERFORM set_config('app.pb_any_item', 'off', true);
END $function$;

-- which partners use each book, and setting them (owners); a partner has one book, so ticking a partner here moves it to this book
CREATE OR REPLACE FUNCTION public.partner_books()
 RETURNS TABLE (partner_id bigint, name text, active boolean, book_id bigint) LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT p.id, p.name::text, coalesce(p.active, true), p.price_book_id FROM partners p WHERE public.current_staff_role() IS NOT NULL ORDER BY p.name
$function$;
CREATE OR REPLACE FUNCTION public.partner_books_set(p_book bigint, p_partners bigint[])
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only an owner can pick a partner''s price book'; END IF;
  IF NOT EXISTS (SELECT 1 FROM price_books WHERE id = p_book) THEN RAISE EXCEPTION 'That price book no longer exists'; END IF;
  UPDATE partners SET price_book_id = NULL WHERE price_book_id = p_book AND NOT (id = ANY (coalesce(p_partners, '{}')));
  UPDATE partners SET price_book_id = p_book WHERE id = ANY (coalesce(p_partners, '{}'));
  BEGIN
    INSERT INTO audit_log (table_name, record_id, action, new_values, changed_by)
      SELECT 'price_books', p_book, 'update', jsonb_build_object('partners', p_partners), public.current_app_user_id();
  EXCEPTION WHEN OTHERS THEN NULL;   -- the log is nice to have; never stop the change for it
  END;
END $function$;

-- Vista Credit was connected to the Vista book once, straight in the database on Nov 12 (data, so not here: a later change by Carlo stays).

REVOKE EXECUTE ON FUNCTION public.inv_price_book(bigint), public.inv_item_search_book(bigint, text, integer), public.partner_books(), public.partner_books_set(bigint, bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inv_price_book(bigint), public.inv_item_search_book(bigint, text, integer), public.partner_books(), public.partner_books_set(bigint, bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

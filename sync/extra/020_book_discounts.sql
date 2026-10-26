-- Discounts are set per price book (not per person): everyone on that book sees it on their price book and print book,
-- and can add the item with the discount to a proposal or invoice. Replaces 019 (per person). Safe to run more than once.
DROP FUNCTION IF EXISTS public.pb_disc_people();
DROP FUNCTION IF EXISTS public.pb_disc_list(bigint);
DROP FUNCTION IF EXISTS public.pb_disc_set(bigint, bigint, text, numeric, text);
DROP TABLE IF EXISTS public.pb_tech_discounts;

CREATE TABLE IF NOT EXISTS public.pb_book_discounts (
  item_id bigint NOT NULL REFERENCES public.pricebook_items(id) ON DELETE CASCADE,
  book_id bigint NOT NULL REFERENCES public.price_books(id) ON DELETE CASCADE,
  kind text NOT NULL DEFAULT 'amount' CHECK (kind IN ('amount', 'pct')),
  value numeric(12,2) NOT NULL CHECK (value > 0),
  note text,
  set_by bigint,
  set_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (item_id, book_id)
);
ALTER TABLE public.pb_book_discounts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pb_book_discounts FROM anon, authenticated;

-- the price books, with who is on each (for the drop-down)
CREATE OR REPLACE FUNCTION public.pb_disc_books()
RETURNS TABLE (id bigint, name text, people text) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT (public.has_permission('pricebook.edit') OR coalesce(public._is_owner(), false)) THEN RAISE EXCEPTION 'You can''t change the price book'; END IF;
  RETURN QUERY SELECT b.id, b.name::text,
    (SELECT string_agg(coalesce(nullif(btrim(concat_ws(' ', e.first_name, e.last_name)), ''), u.login_email::text), ', ' ORDER BY e.first_name)
       FROM app_users u LEFT JOIN employees e ON e.id = u.employee_id WHERE u.price_book_id = b.id AND u.active IS TRUE)::text
    FROM price_books b ORDER BY b.name;
END $f$;

-- the discounts on one item (for the item page)
CREATE OR REPLACE FUNCTION public.pb_disc_list(p_item bigint)
RETURNS TABLE (book_id bigint, name text, people text, kind text, value numeric, note text, set_at timestamptz) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT (public.has_permission('pricebook.edit') OR coalesce(public._is_owner(), false)) THEN RAISE EXCEPTION 'You can''t change the price book'; END IF;
  RETURN QUERY SELECT d.book_id, b.name::text,
    (SELECT string_agg(coalesce(nullif(btrim(concat_ws(' ', e.first_name, e.last_name)), ''), u.login_email::text), ', ' ORDER BY e.first_name)
       FROM app_users u LEFT JOIN employees e ON e.id = u.employee_id WHERE u.price_book_id = b.id AND u.active IS TRUE)::text,
    d.kind, d.value, d.note, d.set_at
    FROM pb_book_discounts d JOIN price_books b ON b.id = d.book_id WHERE d.item_id = p_item ORDER BY b.name;
END $f$;

-- add or change one (p_value null or 0 takes it off)
CREATE OR REPLACE FUNCTION public.pb_disc_set(p_item bigint, p_book bigint, p_kind text, p_value numeric, p_note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT (public.has_permission('pricebook.edit') OR coalesce(public._is_owner(), false)) THEN RAISE EXCEPTION 'You can''t change the price book'; END IF;
  IF coalesce(p_value, 0) <= 0 THEN DELETE FROM pb_book_discounts WHERE item_id = p_item AND book_id = p_book; RETURN; END IF;
  IF p_kind NOT IN ('amount', 'pct') THEN RAISE EXCEPTION 'Pick $ or %%'; END IF;
  IF p_kind = 'pct' AND p_value > 100 THEN RAISE EXCEPTION 'A percent can''t be more than 100'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pricebook_items WHERE id = p_item) THEN RAISE EXCEPTION 'That part no longer exists'; END IF;
  IF NOT EXISTS (SELECT 1 FROM price_books WHERE id = p_book) THEN RAISE EXCEPTION 'That price book no longer exists'; END IF;
  INSERT INTO pb_book_discounts (item_id, book_id, kind, value, note, set_by, set_at)
    VALUES (p_item, p_book, p_kind, p_value, nullif(btrim(left(coalesce(p_note, ''), 200)), ''), public.current_app_user_id(), now())
    ON CONFLICT (item_id, book_id) DO UPDATE SET kind = EXCLUDED.kind, value = EXCLUDED.value, note = EXCLUDED.note, set_by = EXCLUDED.set_by, set_at = now();
END $f$;

-- the discounts on the signed-in person's price book
CREATE OR REPLACE FUNCTION public.my_pb_discounts()
RETURNS TABLE (item_id bigint, name text, sku text, unit_price numeric, kind text, value numeric, note text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT d.item_id, i.name::text, i.sku::text, i.unit_price, d.kind, d.value, d.note
  FROM app_users u JOIN pb_book_discounts d ON d.book_id = u.price_book_id JOIN pricebook_items i ON i.id = d.item_id
  WHERE u.id = public.current_app_user_id() AND i.active IS TRUE ORDER BY i.name
$f$;

REVOKE EXECUTE ON FUNCTION public.pb_disc_books(), public.pb_disc_list(bigint), public.pb_disc_set(bigint, bigint, text, numeric, text), public.my_pb_discounts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_disc_books(), public.pb_disc_list(bigint), public.pb_disc_set(bigint, bigint, text, numeric, text), public.my_pb_discounts() TO authenticated;
NOTIFY pgrst, 'reload schema';

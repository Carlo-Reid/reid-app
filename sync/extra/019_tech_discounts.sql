-- Discounts for one person's book: on a price book item, the office picks a tech or sales person and sets money off
-- ($ or %). It shows on that person's price book and print book, and they can add the item with the discount to a
-- proposal or invoice in one click. Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.pb_tech_discounts (
  item_id bigint NOT NULL REFERENCES public.pricebook_items(id) ON DELETE CASCADE,
  user_id bigint NOT NULL REFERENCES public.app_users(id) ON DELETE CASCADE,
  kind text NOT NULL DEFAULT 'amount' CHECK (kind IN ('amount', 'pct')),
  value numeric(12,2) NOT NULL CHECK (value > 0),
  note text,
  set_by bigint,
  set_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (item_id, user_id)
);
ALTER TABLE public.pb_tech_discounts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pb_tech_discounts FROM anon, authenticated;

-- the people a discount can be given to (active staff), for the drop-down
CREATE OR REPLACE FUNCTION public.pb_disc_people()
RETURNS TABLE (id bigint, name text, role text) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT (public.has_permission('pricebook.edit') OR coalesce(public._is_owner(), false)) THEN RAISE EXCEPTION 'You can''t change the price book'; END IF;
  RETURN QUERY SELECT u.id::bigint, coalesce(nullif(btrim(concat_ws(' ', e.first_name, e.last_name)), ''), u.login_email)::text, u.role::text
    FROM app_users u LEFT JOIN employees e ON e.id = u.employee_id
    WHERE u.active IS TRUE ORDER BY 2;
END $f$;

-- the discounts on one item (for the item page)
CREATE OR REPLACE FUNCTION public.pb_disc_list(p_item bigint)
RETURNS TABLE (user_id bigint, name text, kind text, value numeric, note text, set_at timestamptz) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT (public.has_permission('pricebook.edit') OR coalesce(public._is_owner(), false)) THEN RAISE EXCEPTION 'You can''t change the price book'; END IF;
  RETURN QUERY SELECT d.user_id, coalesce(nullif(btrim(concat_ws(' ', e.first_name, e.last_name)), ''), u.login_email)::text, d.kind, d.value, d.note, d.set_at
    FROM pb_tech_discounts d JOIN app_users u ON u.id = d.user_id LEFT JOIN employees e ON e.id = u.employee_id
    WHERE d.item_id = p_item ORDER BY 2;
END $f$;

-- add or change one (p_value null or 0 takes it off)
CREATE OR REPLACE FUNCTION public.pb_disc_set(p_item bigint, p_user bigint, p_kind text, p_value numeric, p_note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT (public.has_permission('pricebook.edit') OR coalesce(public._is_owner(), false)) THEN RAISE EXCEPTION 'You can''t change the price book'; END IF;
  IF coalesce(p_value, 0) <= 0 THEN DELETE FROM pb_tech_discounts WHERE item_id = p_item AND user_id = p_user; RETURN; END IF;
  IF p_kind NOT IN ('amount', 'pct') THEN RAISE EXCEPTION 'Pick $ or %%'; END IF;
  IF p_kind = 'pct' AND p_value > 100 THEN RAISE EXCEPTION 'A percent can''t be more than 100'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pricebook_items WHERE id = p_item) THEN RAISE EXCEPTION 'That part no longer exists'; END IF;
  IF NOT EXISTS (SELECT 1 FROM app_users WHERE id = p_user) THEN RAISE EXCEPTION 'That person isn''t on the staff list'; END IF;
  INSERT INTO pb_tech_discounts (item_id, user_id, kind, value, note, set_by, set_at)
    VALUES (p_item, p_user, p_kind, p_value, nullif(btrim(left(coalesce(p_note, ''), 200)), ''), public.current_app_user_id(), now())
    ON CONFLICT (item_id, user_id) DO UPDATE SET kind = EXCLUDED.kind, value = EXCLUDED.value, note = EXCLUDED.note, set_by = EXCLUDED.set_by, set_at = now();
END $f$;

-- the signed-in person's own discounts (shown on their price book, print book, proposals and invoices)
CREATE OR REPLACE FUNCTION public.my_pb_discounts()
RETURNS TABLE (item_id bigint, name text, sku text, unit_price numeric, kind text, value numeric, note text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT d.item_id, i.name::text, i.sku::text, i.unit_price, d.kind, d.value, d.note
  FROM pb_tech_discounts d JOIN pricebook_items i ON i.id = d.item_id
  WHERE d.user_id = public.current_app_user_id() AND i.active IS TRUE ORDER BY i.name
$f$;

REVOKE EXECUTE ON FUNCTION public.pb_disc_people(), public.pb_disc_list(bigint), public.pb_disc_set(bigint, bigint, text, numeric, text), public.my_pb_discounts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_disc_people(), public.pb_disc_list(bigint), public.pb_disc_set(bigint, bigint, text, numeric, text), public.my_pb_discounts() TO authenticated;
NOTIFY pgrst, 'reload schema';

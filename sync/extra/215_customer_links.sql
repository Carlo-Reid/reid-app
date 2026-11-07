-- Connected customer files (e.g. a landlord and each of their rental properties): any number, both ways, with an optional note.
-- (A move stays its own link: customers.moved_from_customer_id, so the old home's notes and years come along.)
CREATE TABLE IF NOT EXISTS public.customer_links (
  a bigint NOT NULL, b bigint NOT NULL, note text, added_by text, added_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (a, b), CHECK (a < b));
ALTER TABLE public.customer_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_links FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.customer_links_get(p_id bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', c.display_name, 'note', k.note, 'at', k.added_at,
      'address', (SELECT concat_ws(', ', nullif(l.street, ''), nullif(l.city, '')) FROM locations l WHERE l.customer_id = c.id ORDER BY l.active DESC, l.id LIMIT 1)) ORDER BY k.added_at)
    FROM customer_links k JOIN customers c ON c.id = CASE WHEN k.a = p_id THEN k.b ELSE k.a END
    WHERE k.a = p_id OR k.b = p_id), '[]'::jsonb);
END $function$;

CREATE OR REPLACE FUNCTION public.customer_link_set(p_one bigint, p_two bigint, p_on boolean, p_note text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Staff only'; END IF;
  IF p_one = p_two THEN RAISE EXCEPTION 'A file can''t be connected to itself'; END IF;
  IF p_on THEN
    INSERT INTO customer_links (a, b, note, added_by) VALUES (least(p_one, p_two), greatest(p_one, p_two), nullif(btrim(p_note), ''), auth.jwt() ->> 'email')
    ON CONFLICT (a, b) DO UPDATE SET note = coalesce(EXCLUDED.note, customer_links.note);
  ELSE DELETE FROM customer_links WHERE a = least(p_one, p_two) AND b = greatest(p_one, p_two); END IF;
END $function$;
REVOKE EXECUTE ON FUNCTION public.customer_links_get(bigint), public.customer_link_set(bigint, bigint, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_links_get(bigint), public.customer_link_set(bigint, bigint, boolean, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

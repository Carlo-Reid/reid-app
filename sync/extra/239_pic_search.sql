-- Pictures from the web for a new price list item (Carlo, Nov 9): the app shows pictures for a part number and one click loads the picture.
-- The search is done by the pic-search Edge Function with a SerpApi key (free plan: 250 searches a month), kept in the locked vault
-- (name serpapi_key). An owner pastes it once in the app; it is never sent back to the app. Each search is counted here. Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.pic_searches (id bigserial PRIMARY KEY, user_id bigint, q text, n int, at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.pic_searches ENABLE ROW LEVEL SECURITY;

-- who may search: people who can change the price list. Returns their app user id, or NULL.
CREATE OR REPLACE FUNCTION public.pic_search_allowed() RETURNS bigint
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.has_permission('pricebook.edit') THEN public.current_app_user_id() END $f$;

-- for the app: is the key in, how many searches this month
CREATE OR REPLACE FUNCTION public.pic_search_state() RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT jsonb_build_object('has_key', EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'serpapi_key'), 'owner', public._is_owner(),
    'used', (SELECT count(*) FROM pic_searches WHERE at >= date_trunc('month', now())), 'free', 250) $f$;

-- an owner saves (or replaces) the key; '' takes it out
CREATE OR REPLACE FUNCTION public.pic_search_set_key(p_key text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_id uuid; v_key text := btrim(coalesce(p_key, ''));
BEGIN
  IF NOT public._is_owner() THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  IF v_key <> '' AND v_key !~ '^[A-Za-z0-9]{32,100}$' THEN RAISE EXCEPTION 'That does not look like a SerpApi key. It is a long row of letters and numbers with no spaces.'; END IF;
  SELECT id INTO v_id FROM vault.secrets WHERE name = 'serpapi_key';
  IF v_key = '' THEN IF v_id IS NOT NULL THEN DELETE FROM vault.secrets WHERE id = v_id; END IF; RETURN jsonb_build_object('saved', false); END IF;
  IF v_id IS NULL THEN PERFORM vault.create_secret(v_key, 'serpapi_key', 'Picture search for new price list items (SerpApi)');
  ELSE PERFORM vault.update_secret(v_id, v_key); END IF;
  RETURN jsonb_build_object('saved', true);
END $function$;

-- only the Edge Function (service role) may read the key and write the count
CREATE OR REPLACE FUNCTION public._pic_search_key() RETURNS text
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'serpapi_key' LIMIT 1 $f$;
CREATE OR REPLACE FUNCTION public._pic_search_log(p_user bigint, p_q text, p_n int) RETURNS void
 LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  INSERT INTO pic_searches (user_id, q, n) VALUES (p_user, left(p_q, 200), p_n) $f$;

REVOKE EXECUTE ON FUNCTION public.pic_search_allowed(), public.pic_search_state(), public.pic_search_set_key(text), public._pic_search_key(), public._pic_search_log(bigint, text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pic_search_allowed(), public.pic_search_state(), public.pic_search_set_key(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public._pic_search_key(), public._pic_search_log(bigint, text, int) TO service_role;
NOTIFY pgrst, 'reload schema';

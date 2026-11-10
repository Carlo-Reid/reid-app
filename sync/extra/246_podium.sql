-- Podium connection (Carlo, Nov 10): the app signs in to Podium once (OAuth), keeps the keys in the locked vault, and the
-- podium Edge Function talks to Podium for the app. An owner pastes the Client ID and Client Secret once in Settings and
-- presses Connect to Podium. Nothing secret is ever sent back to the app. Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.podium_conn (id int PRIMARY KEY DEFAULT 1 CHECK (id = 1), connected_at timestamptz, connected_by bigint,
  token_expires timestamptz, locations jsonb NOT NULL DEFAULT '[]', last_ok timestamptz, last_error text);
ALTER TABLE public.podium_conn ENABLE ROW LEVEL SECURITY;
CREATE TABLE IF NOT EXISTS public.podium_oauth_state (state text PRIMARY KEY, user_id bigint NOT NULL, at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.podium_oauth_state ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public._podium_secret_set(p_name text, p_value text) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM vault.secrets WHERE name = p_name;
  IF coalesce(p_value, '') = '' THEN IF v_id IS NOT NULL THEN DELETE FROM vault.secrets WHERE id = v_id; END IF;
  ELSIF v_id IS NULL THEN PERFORM vault.create_secret(p_value, p_name, 'Podium connection');
  ELSE PERFORM vault.update_secret(v_id, p_value); END IF;
END $f$;

-- who may set it up: owners. Returns their app user id, or NULL.
CREATE OR REPLACE FUNCTION public.podium_allowed() RETURNS bigint
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN coalesce(public._is_owner(), false) THEN public.current_app_user_id() END $f$;

-- for the app: where the connection stands (no keys in here)
CREATE OR REPLACE FUNCTION public.podium_state() RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT jsonb_build_object('owner', coalesce(public._is_owner(), false),
    'has_keys', (SELECT count(*) = 2 FROM vault.secrets WHERE name IN ('podium_client_id', 'podium_client_secret')),
    'connected', EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'podium_refresh_token'),
    'connected_at', (SELECT connected_at FROM podium_conn WHERE id = 1), 'locations', coalesce((SELECT locations FROM podium_conn WHERE id = 1), '[]'::jsonb),
    'last_ok', (SELECT last_ok FROM podium_conn WHERE id = 1), 'last_error', (SELECT last_error FROM podium_conn WHERE id = 1)) $f$;

-- an owner saves the two keys from the Podium developer page; both empty takes everything out (keys and the connection)
CREATE OR REPLACE FUNCTION public.podium_set_keys(p_id text, p_secret text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_i text := btrim(coalesce(p_id, '')); v_s text := btrim(coalesce(p_secret, ''));
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  IF v_i = '' AND v_s = '' THEN
    PERFORM public._podium_secret_set(n, '') FROM unnest(ARRAY['podium_client_id', 'podium_client_secret', 'podium_refresh_token', 'podium_access_token']) n;
    DELETE FROM podium_conn; DELETE FROM podium_oauth_state;
    RETURN jsonb_build_object('saved', false);
  END IF;
  IF v_i ~ '\s' OR length(v_i) NOT BETWEEN 8 AND 300 THEN RAISE EXCEPTION 'The Client ID does not look right. It is one long row of letters and numbers with no spaces.'; END IF;
  IF v_s ~ '\s' OR length(v_s) NOT BETWEEN 16 AND 600 THEN   -- (a count over 255 inside {} is not allowed in a pattern: that was the 'invalid repetition count' error)
  RAISE EXCEPTION 'The Client Secret does not look right. It is one long row of letters and numbers with no spaces.'; END IF;
  PERFORM public._podium_secret_set('podium_client_id', v_i); PERFORM public._podium_secret_set('podium_client_secret', v_s);
  RETURN jsonb_build_object('saved', true);
END $f$;

-- an owner turns the connection off (the two keys stay, so Connect works again)
CREATE OR REPLACE FUNCTION public.podium_disconnect() RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  PERFORM public._podium_secret_set('podium_refresh_token', ''); PERFORM public._podium_secret_set('podium_access_token', '');
  DELETE FROM podium_conn;
  RETURN jsonb_build_object('connected', false);
END $f$;

-- only the Edge Function (service role) from here down
CREATE OR REPLACE FUNCTION public._podium_secrets() RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(jsonb_object_agg(replace(name, 'podium_', ''), decrypted_secret), '{}'::jsonb)
      || jsonb_build_object('expires', (SELECT token_expires FROM podium_conn WHERE id = 1))
    FROM vault.decrypted_secrets WHERE name IN ('podium_client_id', 'podium_client_secret', 'podium_refresh_token', 'podium_access_token') $f$;
CREATE OR REPLACE FUNCTION public._podium_state_new(p_user bigint) RETURNS text
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions' AS $f$
DECLARE v text := 'pod_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
BEGIN
  DELETE FROM podium_oauth_state WHERE at < now() - interval '1 hour';
  INSERT INTO podium_oauth_state (state, user_id) VALUES (v, p_user);
  RETURN v;
END $f$;
CREATE OR REPLACE FUNCTION public._podium_state_use(p_state text, p_user bigint) RETURNS boolean
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v int;
BEGIN
  DELETE FROM podium_oauth_state WHERE state = p_state AND user_id = p_user AND at > now() - interval '20 minutes';
  GET DIAGNOSTICS v = ROW_COUNT; RETURN v = 1;
END $f$;
CREATE OR REPLACE FUNCTION public._podium_save(p_access text, p_refresh text, p_expires timestamptz, p_user bigint, p_locations jsonb, p_error text) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF p_access IS NOT NULL THEN PERFORM public._podium_secret_set('podium_access_token', p_access); END IF;
  IF p_refresh IS NOT NULL THEN PERFORM public._podium_secret_set('podium_refresh_token', p_refresh); END IF;
  INSERT INTO podium_conn (id, connected_at, connected_by) VALUES (1, CASE WHEN p_user IS NOT NULL THEN now() END, p_user) ON CONFLICT (id) DO NOTHING;
  UPDATE podium_conn SET token_expires = coalesce(p_expires, token_expires), locations = coalesce(p_locations, locations),
    connected_at = CASE WHEN p_user IS NOT NULL THEN now() ELSE connected_at END, connected_by = coalesce(p_user, connected_by),
    last_ok = CASE WHEN p_error IS NULL THEN now() ELSE last_ok END, last_error = p_error WHERE id = 1;
END $f$;

REVOKE EXECUTE ON FUNCTION public._podium_secret_set(text, text), public.podium_allowed(), public.podium_state(), public.podium_set_keys(text, text), public.podium_disconnect(),
  public._podium_secrets(), public._podium_state_new(bigint), public._podium_state_use(text, bigint), public._podium_save(text, text, timestamptz, bigint, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.podium_allowed(), public.podium_state(), public.podium_set_keys(text, text), public.podium_disconnect() TO authenticated;
GRANT EXECUTE ON FUNCTION public._podium_secrets(), public._podium_state_new(bigint), public._podium_state_use(text, bigint), public._podium_save(text, text, timestamptz, bigint, jsonb, text) TO service_role;
NOTIFY pgrst, 'reload schema';

-- Carlo, Nov 14, 2:43 p.m.: "when i remote into adam i want to be on the same page as him and if he changes pages i want my view to
-- change and if i change pages i want his to change as well."
-- A remote session: made by an owner right before he signs in as the person. Its token is the key both screens use on the live
-- channel, so only a screen that knows the token can move the other one. It ends on Back to me, or 3 minutes after the last ping.
-- Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.remote_sessions (
  token uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id bigint NOT NULL,
  by_user bigint,
  by_name text,
  started_at timestamptz NOT NULL DEFAULT now(),
  last_seen timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz);
ALTER TABLE public.remote_sessions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS remote_sessions_user ON public.remote_sessions (user_id) WHERE ended_at IS NULL;

-- owners only: start remoting into a person; returns the token
CREATE OR REPLACE FUNCTION public.remote_start(p_user bigint) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_me bigint := public.current_app_user_id(); v_name text; v_tok uuid;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only an owner can remote in.'; END IF;
  SELECT coalesce(nullif(btrim(coalesce(e.first_name, '') || ' ' || coalesce(e.last_name, '')), ''), split_part(u.login_email::text, '@', 1))
    INTO v_name FROM app_users u LEFT JOIN employees e ON e.id = u.employee_id WHERE u.id = v_me;
  UPDATE remote_sessions SET ended_at = now() WHERE user_id = p_user AND ended_at IS NULL;
  INSERT INTO remote_sessions (user_id, by_user, by_name) VALUES (p_user, v_me, v_name) RETURNING token INTO v_tok;
  RETURN v_tok::text;
END $f$;

-- the person's own app: is someone remoted in with me right now?
CREATE OR REPLACE FUNCTION public.remote_mine() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT (SELECT jsonb_build_object('k', s.token::text, 'by', s.by_name)
            FROM remote_sessions s
           WHERE s.user_id = public.current_app_user_id() AND s.ended_at IS NULL AND s.last_seen > now() - interval '3 minutes'
           ORDER BY s.started_at DESC LIMIT 1) $f$;

CREATE OR REPLACE FUNCTION public.remote_ping(p_k text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE remote_sessions SET last_seen = now() WHERE token::text = p_k AND user_id = public.current_app_user_id() AND ended_at IS NULL $f$;

CREATE OR REPLACE FUNCTION public.remote_stop(p_k text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE remote_sessions SET ended_at = now() WHERE token::text = p_k AND user_id = public.current_app_user_id() AND ended_at IS NULL $f$;

REVOKE EXECUTE ON FUNCTION public.remote_start(bigint), public.remote_mine(), public.remote_ping(text), public.remote_stop(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.remote_start(bigint), public.remote_mine(), public.remote_ping(text), public.remote_stop(text) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- "Contact tech" / "Ask the office to call me": a pop-up at the top of the other person's screen
-- ("Call Carlo at the office", or "Nick wants you to call him"), which stays until they press Got it.
-- Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.call_requests (
  id bigserial PRIMARY KEY,
  from_user_id bigint NOT NULL, to_user_id bigint NOT NULL,
  kind text NOT NULL CHECK (kind IN ('call_office', 'call_me')),   -- call_office: office asks a tech to call in; call_me: a tech asks the office to call him
  note text, created_at timestamptz NOT NULL DEFAULT now(), seen_at timestamptz);
CREATE INDEX IF NOT EXISTS call_requests_to_idx ON public.call_requests (to_user_id, seen_at, created_at DESC);
ALTER TABLE public.call_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.call_requests FROM PUBLIC, anon;
GRANT SELECT ON public.call_requests TO authenticated;          -- only for the live pop-up; rows come through the functions below
DROP POLICY IF EXISTS call_requests_mine ON public.call_requests;
CREATE POLICY call_requests_mine ON public.call_requests FOR SELECT TO authenticated
  USING (to_user_id = public.current_app_user_id() OR from_user_id = public.current_app_user_id());
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'call_requests') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.call_requests;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public._app_user_name(p_user bigint) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(nullif(public._emp_name(u.employee_id), ''), split_part(u.login_email::text, '@', 1)) FROM app_users u WHERE u.id = p_user $f$;
CREATE OR REPLACE FUNCTION public._app_user_phone(p_user bigint) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT nullif(btrim(coalesce(to_jsonb(e) ->> 'mobile_phone', to_jsonb(e) ->> 'mobile', to_jsonb(e) ->> 'cell', to_jsonb(e) ->> 'phone', to_jsonb(e) ->> 'phone_number', '')), '')
  FROM app_users u JOIN employees e ON e.id = u.employee_id WHERE u.id = p_user $f$;

-- who I can pick: techs pick from the office (and owners); everyone else picks from the techs
CREATE OR REPLACE FUNCTION public.call_people() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE u bigint := public.current_app_user_id(); v_role text;
BEGIN
  SELECT role INTO v_role FROM app_users WHERE id = u; IF v_role IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', public._app_user_name(a.id), 'role', a.role) ORDER BY public._app_user_name(a.id))
    FROM app_users a
    WHERE a.active AND a.id <> u
      AND CASE WHEN v_role = 'technician' THEN a.role IN ('owner', 'office', 'admin', 'accounting', 'dispatcher', 'warehouse')
               ELSE a.role = 'technician' END), '[]'::jsonb);
END $function$;

CREATE OR REPLACE FUNCTION public.call_request_send(p_to bigint, p_note text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE u bigint := public.current_app_user_id(); v_role text; r call_requests;
BEGIN
  SELECT role INTO v_role FROM app_users WHERE id = u AND active; IF v_role IS NULL THEN RAISE EXCEPTION 'Not signed in'; END IF;
  IF NOT EXISTS (SELECT 1 FROM app_users WHERE id = p_to AND active) THEN RAISE EXCEPTION 'That person isn''t in the app'; END IF;
  INSERT INTO call_requests (from_user_id, to_user_id, kind, note)
  VALUES (u, p_to, CASE WHEN v_role = 'technician' THEN 'call_me' ELSE 'call_office' END, nullif(btrim(left(p_note, 300)), ''))
  RETURNING * INTO r;
  RETURN jsonb_build_object('id', r.id, 'to', public._app_user_name(p_to));
END $function$;

-- the pop-ups waiting for me (last 12 hours, not answered yet)
CREATE OR REPLACE FUNCTION public.my_call_requests() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'kind', r.kind, 'note', r.note, 'at', r.created_at,
           'from_id', r.from_user_id, 'from', public._app_user_name(r.from_user_id), 'phone', public._app_user_phone(r.from_user_id)) ORDER BY r.created_at), '[]'::jsonb)
  FROM call_requests r
  WHERE r.to_user_id = public.current_app_user_id() AND r.seen_at IS NULL AND r.created_at > now() - interval '12 hours' $f$;

CREATE OR REPLACE FUNCTION public.call_request_seen(p_id bigint) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE call_requests SET seen_at = now() WHERE id = p_id AND to_user_id = public.current_app_user_id() AND seen_at IS NULL $f$;

REVOKE EXECUTE ON FUNCTION public._app_user_name(bigint), public._app_user_phone(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.call_people(), public.call_request_send(bigint, text), public.my_call_requests(), public.call_request_seen(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.call_people(), public.call_request_send(bigint, text), public.my_call_requests(), public.call_request_seen(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

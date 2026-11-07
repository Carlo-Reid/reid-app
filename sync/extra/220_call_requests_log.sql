-- Call requests, part 2: Got it (accepted), then "Call back done", and a log.
-- The person who got it sees how long it's been waiting until they press Call back done;
-- then the person who sent it gets a pop-up ("Nick called you back"). Safe to run more than once.
ALTER TABLE public.call_requests ADD COLUMN IF NOT EXISTS done_at timestamptz;          -- Call back done
ALTER TABLE public.call_requests ADD COLUMN IF NOT EXISTS sender_seen_at timestamptz;   -- the sender closed the "called you back" pop-up
-- seen_at (from 219) is when they pressed Got it (accepted)

-- what's on my screen: requests to me not called back yet (last 3 days), and "called you back" notices for ones I sent
CREATE OR REPLACE FUNCTION public.my_call_requests() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(jsonb_agg(x ORDER BY x ->> 'at'), '[]'::jsonb) FROM (
    SELECT jsonb_build_object('id', r.id, 'box', 'todo', 'kind', r.kind, 'note', r.note, 'at', r.created_at, 'accepted', r.seen_at,
             'from_id', r.from_user_id, 'from', public._app_user_name(r.from_user_id), 'phone', public._app_user_phone(r.from_user_id)) AS x
    FROM call_requests r
    WHERE r.to_user_id = public.current_app_user_id() AND r.done_at IS NULL AND r.created_at > now() - interval '3 days'
    UNION ALL
    SELECT jsonb_build_object('id', r.id, 'box', 'done', 'kind', r.kind, 'note', r.note, 'at', r.created_at, 'accepted', r.seen_at, 'done', r.done_at,
             'to', public._app_user_name(r.to_user_id))
    FROM call_requests r
    WHERE r.from_user_id = public.current_app_user_id() AND r.done_at IS NOT NULL AND r.sender_seen_at IS NULL AND r.done_at > now() - interval '3 days') q $f$;

CREATE OR REPLACE FUNCTION public.call_request_done(p_id bigint) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE call_requests SET done_at = now(), seen_at = coalesce(seen_at, now())
   WHERE id = p_id AND to_user_id = public.current_app_user_id() AND done_at IS NULL $f$;
CREATE OR REPLACE FUNCTION public.call_request_ack(p_id bigint) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE call_requests SET sender_seen_at = now() WHERE id = p_id AND from_user_id = public.current_app_user_id() AND sender_seen_at IS NULL $f$;

-- the log: what I sent and got (owners see everyone's), newest first
CREATE OR REPLACE FUNCTION public.call_request_log(p_days integer DEFAULT 30) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'kind', r.kind, 'note', r.note, 'at', r.created_at, 'accepted', r.seen_at, 'done', r.done_at,
           'from_id', r.from_user_id, 'from', public._app_user_name(r.from_user_id), 'to_id', r.to_user_id, 'to', public._app_user_name(r.to_user_id))
         ORDER BY r.created_at DESC), '[]'::jsonb)
  FROM call_requests r
  WHERE r.created_at > now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 400))
    AND (r.from_user_id = public.current_app_user_id() OR r.to_user_id = public.current_app_user_id()
         OR EXISTS (SELECT 1 FROM app_users u WHERE u.id = public.current_app_user_id() AND u.role = 'owner')) $f$;

REVOKE EXECUTE ON FUNCTION public.call_request_done(bigint), public.call_request_ack(bigint), public.call_request_log(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.call_request_done(bigint), public.call_request_ack(bigint), public.call_request_log(integer), public.my_call_requests() TO authenticated;
NOTIFY pgrst, 'reload schema';

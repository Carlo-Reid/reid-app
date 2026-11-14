-- Carlo, Nov 14, 2:21 p.m.: "if a login is used in 2 locations let the owners know that by showing the name on the side with second
-- location open and if i click on that name have it open and remote into their current page."
-- Each open app (one browser on one device) has its own id, kept in that browser; its heartbeat also says which page it is on.
-- Two live heartbeats of one login with two different ids = that login is open in 2 places. Safe to run more than once.
ALTER TABLE public.staff_logins ADD COLUMN IF NOT EXISTS client_id text;
ALTER TABLE public.staff_logins ADD COLUMN IF NOT EXISTS page text;
ALTER TABLE public.staff_logins ADD COLUMN IF NOT EXISTS hash text;
CREATE INDEX IF NOT EXISTS staff_logins_live ON public.staff_logins (last_seen) WHERE ended_at IS NULL;

-- the heartbeat: I am still here, in this browser, on this page
CREATE OR REPLACE FUNCTION public.login_beat(p_id bigint, p_client text, p_page text, p_hash text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE staff_logins SET last_seen = now(), client_id = left(nullif(btrim(p_client), ''), 60), page = left(p_page, 80), hash = left(p_hash, 200)
   WHERE id = p_id AND user_id = public.current_app_user_id() AND ended_at IS NULL $f$;
REVOKE EXECUTE ON FUNCTION public.login_beat(bigint, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.login_beat(bigint, text, text, text) TO authenticated;

-- owners only: every login that is open in 2 or more places right now (seen in the last 3 minutes), with each place's device and page.
-- p_client = the asking browser's own id, so its own place is marked "here".
CREATE OR REPLACE FUNCTION public.second_locations(p_client text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS DISTINCT FROM 'owner' THEN '[]'::jsonb ELSE coalesce((
    WITH live AS (
      SELECT DISTINCT ON (l.user_id, l.client_id) l.user_id, l.client_id, l.device, l.page, l.hash, l.last_seen
        FROM staff_logins l
       WHERE l.ended_at IS NULL AND l.event <> 'sign_out' AND l.client_id IS NOT NULL AND l.last_seen > now() - interval '3 minutes'
       ORDER BY l.user_id, l.client_id, l.last_seen DESC),
    multi AS (SELECT user_id FROM live GROUP BY user_id HAVING count(*) >= 2)
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', u.id,
             'name', coalesce(nullif(btrim(coalesce(e.first_name, '') || ' ' || coalesce(e.last_name, '')), ''), split_part(u.login_email::text, '@', 1)),
             'places', (SELECT jsonb_agg(jsonb_build_object('device', v.device, 'page', v.page, 'hash', v.hash, 'seen', v.last_seen,
                                                            'here', (u.id = public.current_app_user_id() AND v.client_id = p_client)) ORDER BY v.last_seen DESC)
                          FROM live v WHERE v.user_id = u.id)) ORDER BY u.id)
      FROM multi m JOIN app_users u ON u.id = m.user_id LEFT JOIN employees e ON e.id = u.employee_id), '[]'::jsonb) END $f$;
REVOKE EXECUTE ON FUNCTION public.second_locations(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.second_locations(text) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Carlo, Nov 14, 2:39 p.m.: "click on a name on my left side bar and remote in to that employee… go right into the page he is on".
-- owners only: the page each person who is online has open right now (their newest live place, seen in the last 3 minutes).
CREATE OR REPLACE FUNCTION public.online_places() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS DISTINCT FROM 'owner' THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('user_id', v.user_id, 'device', v.device, 'page', v.page, 'hash', v.hash, 'seen', v.last_seen))
      FROM (SELECT DISTINCT ON (l.user_id) l.user_id, l.device, l.page, l.hash, l.last_seen
              FROM staff_logins l
             WHERE l.ended_at IS NULL AND l.event <> 'sign_out' AND l.client_id IS NOT NULL AND l.last_seen > now() - interval '3 minutes'
             ORDER BY l.user_id, l.last_seen DESC) v), '[]'::jsonb) END $f$;
REVOKE EXECUTE ON FUNCTION public.online_places() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.online_places() TO authenticated;
NOTIFY pgrst, 'reload schema';

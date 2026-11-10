-- Eco Man dances when someone clicks the same do-nothing spot more than 20 times, and "lets the boss know":
-- each dance is written here and owners see the last week's on the Auto update page. (Carlo, Nov 9.) Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.eco_dances (id bigserial PRIMARY KEY, user_id bigint, who text, page text, place text, at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.eco_dances ENABLE ROW LEVEL SECURITY;
CREATE OR REPLACE FUNCTION public.eco_dance_log(p_page text, p_place text) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE u bigint := public.current_app_user_id();
BEGIN
  IF u IS NULL THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM eco_dances WHERE user_id = u AND at > now() - interval '20 seconds') THEN RETURN; END IF;
  INSERT INTO eco_dances (user_id, who, page, place) VALUES (u, public._app_user_name(u), left(coalesce(p_page, ''), 60), left(coalesce(p_place, ''), 120));
END $function$;
CREATE OR REPLACE FUNCTION public.eco_dance_list(p_days integer DEFAULT 7) RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._is_owner() THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('who', d.who, 'page', d.page, 'place', d.place, 'at', d.at) ORDER BY d.at DESC)
      FROM (SELECT * FROM eco_dances WHERE at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 60))) ORDER BY at DESC LIMIT 20) d), '[]'::jsonb) END $f$;
REVOKE EXECUTE ON FUNCTION public.eco_dance_log(text, text), public.eco_dance_list(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eco_dance_log(text, text), public.eco_dance_list(integer) TO authenticated;
NOTIFY pgrst, 'reload schema';

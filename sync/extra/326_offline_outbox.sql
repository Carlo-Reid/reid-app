-- Carlo, Nov 20, 2026, 10:34 a.m.: "when a tech is in a call taking pictures and working sometimes they loose internet connection, when that
-- happens and it re-connects later I need any info that was not uploaded to the program to get uploaded."
-- The app keeps what could not be sent on the phone (a "waiting to send" list) and sends it when the internet is back. What is sent late
-- carries the time the tech really pressed the button, so the pay times (en_route_at, arrived_at, completed_at) are the real ones.
-- These functions are only called for something sent late; with internet the app calls the older functions as before.

-- what was sent late, so an owner can see it: pressed at, sent at
CREATE TABLE IF NOT EXISTS public.late_sends (
  id bigserial PRIMARY KEY, visit_id bigint, what text NOT NULL, pressed_at timestamptz NOT NULL, sent_at timestamptz NOT NULL DEFAULT now(), by_user bigint);
ALTER TABLE public.late_sends ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS late_sends_visit_idx ON public.late_sends (visit_id);

-- the time a button was pressed, as the phone says it: never in the future, never more than 36 hours ago (then it is "now")
CREATE OR REPLACE FUNCTION public._pressed_at(p_at timestamptz) RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p_at IS NULL OR p_at > now() + interval '2 minutes' OR p_at < now() - interval '36 hours' THEN now() ELSE least(p_at, now()) END $$;

-- the times of a call follow its status. Same rules as before; the time is the pressed time when one of the functions below set it.
CREATE OR REPLACE FUNCTION public._visit_times() RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE v_at timestamptz := now(); v_set text := nullif(current_setting('app.pressed_at', true), '');
BEGIN
  IF v_set IS NOT NULL THEN BEGIN v_at := v_set::timestamptz; EXCEPTION WHEN OTHERS THEN v_at := now(); END; END IF;
  IF NEW.status IS DISTINCT FROM coalesce(OLD.status, '') THEN
    IF NEW.status = 'on_site' AND NEW.arrived_at IS NULL THEN NEW.arrived_at := v_at; END IF;
    IF NEW.status = 'en_route' AND NEW.en_route_at IS NULL THEN NEW.en_route_at := v_at; END IF;
    IF NEW.status IN ('scheduled', 'dispatched', 'unscheduled') THEN NEW.arrived_at := NULL; NEW.en_route_at := NULL; END IF;   -- Undo
    IF NEW.status = 'en_route' THEN NEW.arrived_at := NULL; END IF;
  END IF;
  RETURN NEW;
END $function$;

-- a status button (On my way, I'm here, Done, Needs another visit) that was pressed with no internet
CREATE OR REPLACE FUNCTION public.call_status_at(p_visit_id bigint, p_status text, p_note text, p_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_at timestamptz := public._pressed_at(p_at); v_done timestamptz; r jsonb;
BEGIN
  SELECT completed_at INTO v_done FROM visits WHERE id = p_visit_id;
  PERFORM set_config('app.pressed_at', v_at::text, true);
  r := public.set_call_status(p_visit_id, p_status, p_note);
  PERFORM set_config('app.pressed_at', '', true);
  IF p_status IN ('completed', 'needs_return') AND v_done IS NULL THEN
    UPDATE visits SET completed_at = v_at WHERE id = p_visit_id AND completed_at > v_at AND (arrived_at IS NULL OR arrived_at <= v_at);
  END IF;
  IF v_at < now() - interval '2 minutes' THEN
    INSERT INTO late_sends (visit_id, what, pressed_at, by_user) VALUES (p_visit_id, 'status: ' || p_status, v_at, public.current_app_user_id());
  END IF;
  RETURN r;
END $function$;

-- a location stamp (way / start / end) that was taken with no internet
CREATE OR REPLACE FUNCTION public.call_place_at(p_visit bigint, p_kind text, p_lat double precision, p_lng double precision, p_acc numeric, p_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_at timestamptz := public._pressed_at(p_at); r jsonb;
BEGIN
  r := public.call_place_set(p_visit, p_kind, p_lat, p_lng, p_acc);
  IF coalesce((r ->> 'ok')::boolean, false) THEN
    UPDATE on_way_places SET at = v_at
     WHERE id = (SELECT max(id) FROM on_way_places WHERE visit_id = p_visit AND kind = p_kind AND by_user = public.current_app_user_id());
  END IF;
  RETURN r;
END $function$;

-- Complete the call on a walk, pressed with no internet
CREATE OR REPLACE FUNCTION public.walk_complete_at(p_visit_id bigint, p_notes text, p_signer text, p_png text, p_at timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_at timestamptz := public._pressed_at(p_at); v_done timestamptz;
BEGIN
  SELECT completed_at INTO v_done FROM visits WHERE id = p_visit_id;
  PERFORM set_config('app.pressed_at', v_at::text, true);
  PERFORM public.walk_complete(p_visit_id, p_notes, p_signer, p_png);
  PERFORM set_config('app.pressed_at', '', true);
  UPDATE walk_results SET done_at = v_at WHERE visit_id = p_visit_id AND done_at > v_at;
  IF v_done IS NULL THEN
    UPDATE visits SET completed_at = v_at WHERE id = p_visit_id AND completed_at > v_at AND (arrived_at IS NULL OR arrived_at <= v_at);
  END IF;
  IF v_at < now() - interval '2 minutes' THEN
    INSERT INTO late_sends (visit_id, what, pressed_at, by_user) VALUES (p_visit_id, 'walk completed', v_at, public.current_app_user_id());
  END IF;
END $function$;

-- "More pictures" on a walk, sent again after a lost answer: the same picture is never added twice
CREATE OR REPLACE FUNCTION public.walk_extra_photo_once(p_visit_id bigint, p_key text, p_size bigint)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_q int;
BEGIN
  SELECT q INTO v_q FROM walk_answers WHERE visit_id = p_visit_id AND storage_key = nullif(btrim(p_key), '') LIMIT 1;
  IF v_q IS NOT NULL THEN RETURN v_q; END IF;
  RETURN public.walk_extra_photo_add(p_visit_id, p_key, p_size);
END $function$;

REVOKE ALL ON FUNCTION public.call_status_at(bigint, text, text, timestamptz), public.call_place_at(bigint, text, double precision, double precision, numeric, timestamptz),
  public.walk_complete_at(bigint, text, text, text, timestamptz), public.walk_extra_photo_once(bigint, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.call_status_at(bigint, text, text, timestamptz), public.call_place_at(bigint, text, double precision, double precision, numeric, timestamptz),
  public.walk_complete_at(bigint, text, text, text, timestamptz), public.walk_extra_photo_once(bigint, text, bigint) TO authenticated;

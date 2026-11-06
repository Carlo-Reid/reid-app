-- Payroll: paid time a tech (or an owner) adds by hand when it wasn't on the schedule, e.g. a call-out at 6:30 am.
-- A tech adds their own (it waits for an owner to approve it); an owner can add, approve or delete anyone's.
CREATE TABLE IF NOT EXISTS public.payroll_events (
  id bigserial PRIMARY KEY, app_user_id bigint NOT NULL, day date NOT NULL, starts time NOT NULL, ends time NOT NULL, what text NOT NULL,
  approved boolean NOT NULL DEFAULT false, added_by text, added_at timestamptz NOT NULL DEFAULT now(), approved_by text, approved_at timestamptz);
CREATE INDEX IF NOT EXISTS payroll_events_user_day ON public.payroll_events (app_user_id, day);
ALTER TABLE public.payroll_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_events FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._payroll_can(p_user bigint) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT public.current_staff_role() = 'owner' OR p_user = public.current_app_user_id() $function$;

CREATE OR REPLACE FUNCTION public.payroll_events_list(p_user bigint, p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._payroll_can(p_user) THEN RETURN '[]'::jsonb; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'day', day, 'starts', to_char(starts, 'HH24:MI'), 'ends', to_char(ends, 'HH24:MI'), 'what', what,
      'approved', approved, 'added_by', added_by, 'approved_by', approved_by) ORDER BY day, starts)
    FROM public.payroll_events WHERE app_user_id = p_user AND day BETWEEN p_from AND p_to), '[]'::jsonb);
END $function$;

CREATE OR REPLACE FUNCTION public.payroll_event_add(p_user bigint, p_day date, p_starts time, p_ends time, p_what text) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_owner boolean := public.current_staff_role() = 'owner'; v_id bigint;
BEGIN
  IF NOT public._payroll_can(p_user) THEN RAISE EXCEPTION 'You can only add to your own payroll'; END IF;
  IF p_ends <= p_starts THEN RAISE EXCEPTION 'The end time has to be after the start time'; END IF;
  IF COALESCE(btrim(p_what), '') = '' THEN RAISE EXCEPTION 'Say what the event was'; END IF;
  INSERT INTO public.payroll_events (app_user_id, day, starts, ends, what, approved, added_by, approved_by, approved_at)
  VALUES (p_user, p_day, p_starts, p_ends, btrim(p_what), v_owner, auth.jwt() ->> 'email', CASE WHEN v_owner THEN auth.jwt() ->> 'email' END, CASE WHEN v_owner THEN now() END)
  RETURNING id INTO v_id; RETURN v_id;
END $function$;

CREATE OR REPLACE FUNCTION public.payroll_event_approve(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only owners can approve'; END IF;
  UPDATE public.payroll_events SET approved = true, approved_by = auth.jwt() ->> 'email', approved_at = now() WHERE id = p_id;
END $function$;

CREATE OR REPLACE FUNCTION public.payroll_event_del(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE r public.payroll_events;
BEGIN
  SELECT * INTO r FROM public.payroll_events WHERE id = p_id; IF NOT FOUND THEN RETURN; END IF;
  IF NOT (public.current_staff_role() = 'owner' OR (r.app_user_id = public.current_app_user_id() AND NOT r.approved)) THEN RAISE EXCEPTION 'Only an owner can remove an approved event'; END IF;
  DELETE FROM public.payroll_events WHERE id = p_id;
END $function$;
REVOKE EXECUTE ON FUNCTION public._payroll_can(bigint), public.payroll_events_list(bigint, date, date), public.payroll_event_add(bigint, date, time, time, text), public.payroll_event_approve(bigint), public.payroll_event_del(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_events_list(bigint, date, date), public.payroll_event_add(bigint, date, time, time, text), public.payroll_event_approve(bigint), public.payroll_event_del(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Who is on call each day (from Carlo's Shifter calendar): the tech on call, and the second person on call.
-- Shown on the dispatch board (a strip above Waiting for a day, and a 📟 tag on their line). Changed there by clicking the strip.
-- The rows below are only added when the day has nothing yet, so changes made in the app stay. Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.on_call (day date PRIMARY KEY, first_name text, second_name text, set_by text, set_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.on_call ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.on_call FROM PUBLIC, anon, authenticated;
INSERT INTO public.on_call (day, first_name, second_name, set_by) VALUES
  ('2026-11-01', 'Youssef', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-02', 'Youssef', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-03', 'Mina', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-04', 'Mina', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-05', 'Mina', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-06', 'Colin', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-07', 'Colin', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-08', 'Colin', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-09', 'Colin', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-10', 'Lucas', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-11', 'Lucas', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-12', 'Lucas', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-13', 'Mina', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-14', 'Mina', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-15', 'Mina', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-16', 'Mina', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-17', 'Phillip', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-18', 'Phillip', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-19', 'Phillip', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-20', 'Lucas', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-21', 'Lucas', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-22', 'Lucas', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-23', 'Lucas', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-11-24', 'Dayton', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-25', 'Dayton', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-26', 'Dayton', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-27', 'Phillip', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-28', 'Phillip', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-29', 'Phillip', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-11-30', 'Phillip', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-12-01', 'Mina', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-02', 'Mina', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-03', 'Mina', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-04', 'Dayton', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-05', 'Dayton', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-06', 'Dayton', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-07', 'Dayton', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-08', 'Scott', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-12-09', 'Scott', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-12-10', 'Scott', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-12-11', 'Mina', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-12-12', 'Mina', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-12-13', 'Mina', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-12-14', 'Mina', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-12-15', 'Kane', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-16', 'Kane', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-17', 'Kane', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-18', 'Scott', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-19', 'Scott', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-20', 'Scott', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-21', 'Scott', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-22', 'Youssef', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-23', 'Youssef', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-24', 'Youssef', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-25', 'Kane', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-12-26', 'Kane', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-12-27', 'Kane', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-12-28', 'Kane', 'Adam', 'Shifter Nov–Dec 2026'),
  ('2026-12-29', 'Nick', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-30', 'Nick', 'Dave', 'Shifter Nov–Dec 2026'),
  ('2026-12-31', 'Nick', 'Dave', 'Shifter Nov–Dec 2026')
ON CONFLICT (day) DO NOTHING;

CREATE OR REPLACE FUNCTION public.on_call_range(p_from date, p_to date) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('day', day, 'first', first_name, 'second', second_name) ORDER BY day)
    FROM on_call WHERE day BETWEEN p_from AND p_to), '[]'::jsonb) END $f$;
CREATE OR REPLACE FUNCTION public.on_call_set(p_day date, p_first text, p_second text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (public.current_staff_role() = 'owner' OR public.has_permission('calls.dispatch')) THEN RAISE EXCEPTION 'Only owners and dispatch can change who is on call'; END IF;
  IF nullif(btrim(p_first), '') IS NULL AND nullif(btrim(p_second), '') IS NULL THEN DELETE FROM on_call WHERE day = p_day; RETURN; END IF;
  INSERT INTO on_call (day, first_name, second_name, set_by) VALUES (p_day, nullif(btrim(p_first), ''), nullif(btrim(p_second), ''), auth.jwt() ->> 'email')
  ON CONFLICT (day) DO UPDATE SET first_name = EXCLUDED.first_name, second_name = EXCLUDED.second_name, set_by = EXCLUDED.set_by, set_at = now();
END $function$;
REVOKE EXECUTE ON FUNCTION public.on_call_range(date, date), public.on_call_set(date, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.on_call_range(date, date), public.on_call_set(date, text, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

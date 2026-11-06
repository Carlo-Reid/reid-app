-- Payroll: a note from the employee for payroll, one per person per pay period (e.g. "Left early Tuesday for the dentist").
-- The employee writes their own; owners see it (and can change it).
CREATE TABLE IF NOT EXISTS public.payroll_notes (
  app_user_id bigint NOT NULL, period_from date NOT NULL, note text NOT NULL DEFAULT '', updated_by text, updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (app_user_id, period_from));
ALTER TABLE public.payroll_notes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_notes FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.payroll_note_get(p_user bigint, p_from date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._payroll_can(p_user) THEN RETURN NULL; END IF;
  RETURN (SELECT jsonb_build_object('note', note, 'by', updated_by, 'at', updated_at) FROM public.payroll_notes WHERE app_user_id = p_user AND period_from = p_from);
END $function$;

CREATE OR REPLACE FUNCTION public.payroll_note_set(p_user bigint, p_from date, p_note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._payroll_can(p_user) THEN RAISE EXCEPTION 'You can only write a note on your own payroll'; END IF;
  INSERT INTO public.payroll_notes (app_user_id, period_from, note, updated_by, updated_at) VALUES (p_user, p_from, coalesce(btrim(p_note), ''), auth.jwt() ->> 'email', now())
  ON CONFLICT (app_user_id, period_from) DO UPDATE SET note = EXCLUDED.note, updated_by = EXCLUDED.updated_by, updated_at = now();
END $function$;
REVOKE EXECUTE ON FUNCTION public.payroll_note_get(bigint, date), public.payroll_note_set(bigint, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_note_get(bigint, date), public.payroll_note_set(bigint, date, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

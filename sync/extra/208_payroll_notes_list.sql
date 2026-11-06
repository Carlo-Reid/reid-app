-- Payroll list: who wrote a note for payroll in a pay period. Owners only.
CREATE OR REPLACE FUNCTION public.payroll_notes_period(p_from date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RETURN '[]'::jsonb; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('user', app_user_id, 'note', note, 'at', updated_at))
    FROM public.payroll_notes WHERE period_from = p_from AND btrim(note) <> ''), '[]'::jsonb);
END $function$;
REVOKE EXECUTE ON FUNCTION public.payroll_notes_period(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_notes_period(date) TO authenticated;
NOTIFY pgrst, 'reload schema';

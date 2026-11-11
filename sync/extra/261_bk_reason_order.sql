-- Book a call: the order of the Reason for Call buttons, set by an owner by dragging them, the same for everyone (Carlo, Nov 11, 2026)
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS bk_reason_order jsonb;
CREATE OR REPLACE FUNCTION public.bk_reason_order() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT coalesce((SELECT bk_reason_order FROM company_settings ORDER BY id LIMIT 1), '[]'::jsonb) $function$;
CREATE OR REPLACE FUNCTION public.set_bk_reason_order(p jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only an owner can change the order for everyone'; END IF;
  IF jsonb_typeof(p) <> 'array' OR jsonb_array_length(p) > 60 THEN RAISE EXCEPTION 'That is not a list I can save'; END IF;
  UPDATE company_settings SET bk_reason_order = p WHERE id = (SELECT id FROM company_settings ORDER BY id LIMIT 1);
END $function$;
REVOKE EXECUTE ON FUNCTION public.bk_reason_order(), public.set_bk_reason_order(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bk_reason_order(), public.set_bk_reason_order(jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';

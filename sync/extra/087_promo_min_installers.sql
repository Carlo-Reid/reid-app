-- The book-today promo only offers days with at least this many installers free (keeps room on the schedule)
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS promo_min_installers int NOT NULL DEFAULT 4;
CREATE OR REPLACE FUNCTION public._promo_min() RETURNS int LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT greatest(coalesce((SELECT promo_min_installers FROM company_settings LIMIT 1), 4), 2)
$function$;

CREATE OR REPLACE FUNCTION public.install_hold_cal(p_estimate bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_mon date := public._hold_week();
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('from', v_mon, 'to', v_mon + 29, 'min', public._promo_min(), 'days', public._hold_free(p_estimate, v_mon, v_mon + 29));
END $function$;

CREATE OR REPLACE FUNCTION public.install_hold_days(p_estimate bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_mon date := public._hold_week();
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('from', v_mon, 'to', v_mon + 4, 'min', public._promo_min(),
    'mine', (SELECT jsonb_build_object('id', h.id, 'day', h.day, 'status', h.status) FROM install_holds h WHERE h.estimate_id = p_estimate AND h.status <> 'released'),
    'days', public._hold_free(p_estimate, v_mon, v_mon + 4));
END $function$;

SELECT public._patch_fn('install_hold_set', $o$IF coalesce(v_free, 0) < 2 THEN RAISE EXCEPTION 'That day just filled up. Pick another day.'; END IF;$o$,
  $n$IF coalesce(v_free, 0) < public._promo_min() THEN RAISE EXCEPTION 'That day isn''t available for this promo. Pick another day.'; END IF;$n$);

-- owners: change the number
CREATE OR REPLACE FUNCTION public.set_promo_min_installers(p_n int) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Owner only'; END IF;
  IF p_n IS NULL OR p_n < 2 OR p_n > 20 THEN RAISE EXCEPTION 'Pick a number from 2 to 20'; END IF;
  UPDATE company_settings SET promo_min_installers = p_n;
END $function$;
REVOKE EXECUTE ON FUNCTION public.set_promo_min_installers(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_promo_min_installers(int), public.install_hold_cal(bigint), public.install_hold_days(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- A rebate line can end: offer_expires_at. If the proposal isn't accepted by then, the line comes off.
ALTER TABLE public.estimate_lines ADD COLUMN IF NOT EXISTS offer_expires_at timestamptz;

SELECT public._patch_fn('est_save', 'kit_skip, long_desc, line_kind)', 'kit_skip, long_desc, line_kind, offer_expires_at)');
SELECT public._patch_fn('est_save', '             v_kind
      FROM (SELECT 1) one', '             v_kind, CASE WHEN v_kind IS NULL THEN nullif(ln ->> ''expires'', '''')::timestamptz END
      FROM (SELECT 1) one');

-- take off the offers that ran out on proposals that weren't accepted (one proposal, or all of them)
CREATE OR REPLACE FUNCTION public.est_expire_offers(p_id bigint DEFAULT NULL) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE n int;
BEGIN
  IF p_id IS NOT NULL AND public.current_staff_role() IS NULL THEN RETURN 0; END IF;
  DELETE FROM estimate_lines l USING estimate_options o, estimates e
  WHERE l.estimate_option_id = o.id AND o.estimate_id = e.id AND l.offer_expires_at IS NOT NULL AND l.offer_expires_at < now()
    AND e.status <> 'accepted' AND (p_id IS NULL OR e.id = p_id);
  GET DIAGNOSTICS n = ROW_COUNT; RETURN n;
END $function$;
REVOKE EXECUTE ON FUNCTION public.est_expire_offers(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_expire_offers(bigint) TO authenticated;

-- closing the deal after the time ran out: the offer is gone first
SELECT public._patch_fn('est_close', 'IF e.status = ''accepted'' THEN RAISE EXCEPTION ''This deal is already closed''; END IF;',
  'IF e.status = ''accepted'' THEN RAISE EXCEPTION ''This deal is already closed''; END IF;
  PERFORM public.est_expire_offers(p_id);   -- offer-expiry');

SELECT public.est_expire_offers(NULL);
NOTIFY pgrst, 'reload schema';

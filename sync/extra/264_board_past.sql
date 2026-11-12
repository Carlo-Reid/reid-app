-- Dispatch board and the past (Carlo, Nov 12, 2026):
--  1) calls booked for a day that has passed and were not done: listed at the top of the board ("Past calls not complete yet")
--  2) a note or held spot that repeats: a change or a delete counts from today on; the days in the past stay as they were

CREATE OR REPLACE FUNCTION public.dispatch_past_open(p_today date, p_days int DEFAULT 30)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.scheduled_date, x.arrival_start, x.visit_id), '[]'::jsonb) END
  FROM generate_series(p_today - least(greatest(coalesce(p_days, 30), 1), 90), p_today - 1, interval '1 day') g(d)
  CROSS JOIN LATERAL public.dispatch_day(g.d::date) x
  JOIN jobs j ON j.id = x.job_id
  WHERE x.status IN ('scheduled', 'dispatched', 'en_route', 'on_site')
    AND j.status NOT IN ('completed', 'cancelled', 'on_hold')
$f$;
REVOKE ALL ON FUNCTION public.dispatch_past_open(date, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.dispatch_past_open(date, int) TO authenticated;

CREATE OR REPLACE FUNCTION public.board_note_change(p_id bigint, p jsonb, p_today date)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n board_notes; v_new bigint; v_start date; v_rep text := coalesce(nullif(p ->> 'repeat', ''), 'none'); v_anchor date;
BEGIN
  SELECT * INTO n FROM board_notes WHERE id = p_id AND deleted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'That note was deleted'; END IF;
  IF n.start_date >= p_today THEN RETURN public.save_board_note(p_id, p); END IF;          -- nothing of it is in the past
  IF n.repeat = 'none' THEN RAISE EXCEPTION 'This is on a day in the past. It can not be changed any more.'; END IF;
  v_anchor := coalesce(nullif(p ->> 'start_date', '')::date, n.start_date);
  IF v_anchor >= p_today THEN v_start := v_anchor;
  ELSE SELECT min(g::date) INTO v_start FROM generate_series(p_today, p_today + 400, interval '1 day') g
       WHERE CASE v_rep WHEN 'weekdays' THEN extract(isodow FROM g) < 6 WHEN 'weekly' THEN extract(isodow FROM g) = extract(isodow FROM v_anchor)
                        WHEN 'monthly' THEN extract(day FROM g) = extract(day FROM v_anchor) ELSE true END;
  END IF;
  v_new := public.save_board_note(NULL, p || jsonb_build_object('start_date', coalesce(v_start, p_today)));   -- the new one, from today on (it checks who may)
  UPDATE board_notes SET repeat_until = p_today - 1, updated_at = now() WHERE id = p_id;                       -- the old one stops yesterday
  INSERT INTO board_note_skips (note_id, day) SELECT v_new, s.day FROM board_note_skips s WHERE s.note_id = p_id AND s.day >= p_today ON CONFLICT DO NOTHING;
  RETURN v_new;
END $f$;
REVOKE ALL ON FUNCTION public.board_note_change(bigint, jsonb, date) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.board_note_change(bigint, jsonb, date) TO authenticated;

CREATE OR REPLACE FUNCTION public.board_note_stop(p_id bigint, p_today date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n board_notes;
BEGIN
  IF public.current_staff_role() = 'sales' THEN RAISE EXCEPTION 'Sales people can''t change notes on the board'; END IF;
  IF NOT (public.has_permission('calls.book') OR public.has_permission('calls.dispatch')) THEN RAISE EXCEPTION 'You don''t have permission to change notes on the board'; END IF;
  SELECT * INTO n FROM board_notes WHERE id = p_id AND deleted_at IS NULL;
  IF NOT FOUND THEN RETURN; END IF;
  IF n.start_date >= p_today THEN UPDATE board_notes SET deleted_at = now() WHERE id = p_id;
  ELSIF n.repeat = 'none' THEN RAISE EXCEPTION 'This is on a day in the past. It can not be deleted any more.';
  ELSE UPDATE board_notes SET repeat_until = p_today - 1, updated_at = now() WHERE id = p_id;   -- the days in the past keep it
  END IF;
END $f$;
REVOKE ALL ON FUNCTION public.board_note_stop(bigint, date) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.board_note_stop(bigint, date) TO authenticated;

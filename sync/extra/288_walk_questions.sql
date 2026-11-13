-- The 4 questions a tech answers on a walk (Carlo, Nov 13, 2026): each one gets a picture, saved in the job's photos and files, or N/A.
-- All 4 have to be answered before the walk's call can be completed (the check is in walk_complete, 277_walk_done.sql; the table walk_answers is made there).
-- Owners can change the words of the questions (To be Booked page).
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS walk_questions jsonb;

CREATE OR REPLACE FUNCTION public.walk_questions() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce(
    (SELECT walk_questions FROM company_settings WHERE jsonb_typeof(walk_questions) = 'array' AND jsonb_array_length(walk_questions) = 4 LIMIT 1),
    jsonb_build_array(
      'Take a picture of the old equipment, with its label.',
      'Take a picture of the venting (the pipe that takes the exhaust outside).',
      'Take a picture of the gas line and the water lines.',
      'Take a picture of the way in: the door, the stairs, and the space around it.')) END $f$;

CREATE OR REPLACE FUNCTION public.set_walk_questions(p jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only an owner can change the walk questions'; END IF;
  IF p IS NULL THEN UPDATE company_settings SET walk_questions = NULL; RETURN; END IF;
  IF jsonb_typeof(p) <> 'array' OR jsonb_array_length(p) <> 4
     OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(p) x WHERE nullif(btrim(x), '') IS NULL OR length(x) > 300) THEN
    RAISE EXCEPTION 'Type all 4 questions (300 letters at most each)';
  END IF;
  UPDATE company_settings SET walk_questions = (SELECT jsonb_agg(btrim(x)) FROM jsonb_array_elements_text(p) x);
END $function$;

-- what is answered so far on one walk
CREATE OR REPLACE FUNCTION public.walk_answers_for(p_visit_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(jsonb_build_object('q', a.q, 'na', a.na, 'key', a.storage_key) ORDER BY a.q) FROM walk_answers a WHERE a.visit_id = p_visit_id), '[]'::jsonb) END $f$;

-- one answer: N/A, or the picture the app already put in the job-files bucket under forms/<job>/walk-...
CREATE OR REPLACE FUNCTION public.walk_answer_set(p_visit_id bigint, p_q int, p_question text, p_na boolean, p_key text, p_size bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v visits; v_att bigint; v_key text := nullif(btrim(p_key), '');
BEGIN
  SELECT * INTO v FROM visits WHERE id = p_visit_id;
  IF v.id IS NULL THEN RAISE EXCEPTION 'That call no longer exists'; END IF;
  IF NOT (public.has_permission('calls.dispatch')
          OR EXISTS (SELECT 1 FROM visit_assignments WHERE visit_id = p_visit_id AND employee_id = public.my_employee_id())) THEN
    RAISE EXCEPTION 'You can only answer for calls you''re on';
  END IF;
  IF v.status IN ('completed', 'cancelled') THEN RAISE EXCEPTION 'That call is already closed'; END IF;
  IF p_q IS NULL OR p_q NOT BETWEEN 1 AND 4 THEN RAISE EXCEPTION 'Which question?'; END IF;
  IF coalesce(p_na, false) THEN v_key := NULL;
  ELSIF v_key IS NULL OR v_key NOT LIKE 'forms/' || v.job_id || '/walk-%' THEN RAISE EXCEPTION 'Take a picture, or press N/A';
  ELSE
    INSERT INTO attachments (entity_type, entity_id, category, file_name, storage_key, mime_type, size_bytes, caption, taken_by_employee_id, taken_at)
    VALUES ('job', v.job_id, 'photo', 'Walk question ' || p_q || '.jpg', v_key, 'image/jpeg', p_size, left('Walk: ' || coalesce(p_question, ''), 400), public.my_employee_id(), now())
    RETURNING id INTO v_att;
  END IF;
  INSERT INTO walk_answers (visit_id, q, question, na, storage_key, attachment_id, at, by_user)
  VALUES (p_visit_id, p_q, left(p_question, 300), coalesce(p_na, false), v_key, v_att, now(), public.current_app_user_id())
  ON CONFLICT (visit_id, q) DO UPDATE SET question = excluded.question, na = excluded.na, storage_key = excluded.storage_key, attachment_id = excluded.attachment_id, at = now(), by_user = excluded.by_user;
END $function$;

REVOKE EXECUTE ON FUNCTION public.walk_questions(), public.set_walk_questions(jsonb), public.walk_answers_for(bigint), public.walk_answer_set(bigint, int, text, boolean, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.walk_questions(), public.set_walk_questions(jsonb), public.walk_answers_for(bigint), public.walk_answer_set(bigint, int, text, boolean, text, bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

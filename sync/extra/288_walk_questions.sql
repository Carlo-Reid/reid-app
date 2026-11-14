-- The 4 questions a tech answers on a walk (Carlo, Nov 13, 2026): each one gets a picture, saved in the job's photos and files, or N/A.
-- All 4 have to be answered before the walk's call can be completed (the check is in walk_complete, 277_walk_done.sql; the table walk_answers is made there).
-- Owners change, add and remove the questions on Settings -> Job Types -> HWT Walk (1 to 20 questions; Carlo, Nov 13, 4:58 p.m.).
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS walk_questions jsonb;

CREATE OR REPLACE FUNCTION public.walk_questions() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce(
    (SELECT walk_questions FROM company_settings WHERE jsonb_typeof(walk_questions) = 'array' AND jsonb_array_length(walk_questions) BETWEEN 1 AND 20 LIMIT 1),
    jsonb_build_array(
      'Take a picture of the old equipment, with its label.',
      'Take a picture of the venting (the pipe that takes the exhaust outside).',
      'Take a picture of the gas line and the water lines.',
      'Take a picture of the way in: the door, the stairs, and the space around it.')) END $f$;

CREATE OR REPLACE FUNCTION public.set_walk_questions(p jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only an owner can change the walk questions'; END IF;
  IF p IS NULL THEN UPDATE company_settings SET walk_questions = NULL WHERE true; RETURN; END IF;
  IF jsonb_typeof(p) <> 'array' OR jsonb_array_length(p) NOT BETWEEN 1 AND 20
     OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(p) x WHERE nullif(btrim(x), '') IS NULL OR length(x) > 300) THEN
    RAISE EXCEPTION 'Type every question (1 to 20 questions, 300 letters at most each)';
  END IF;
  UPDATE company_settings SET walk_questions = (SELECT jsonb_agg(btrim(x)) FROM jsonb_array_elements_text(p) x) WHERE true;   -- the database refuses an UPDATE with no WHERE for signed-in people
END $function$;

-- what is answered so far on one walk
-- Carlo, Nov 14, 2:25 p.m.: "if a second picture for a question is taken have it show as well and not replace the first one and have a
-- way for the tech to delete the picture". A question can hold several pictures now, so the one-row-per-question key is gone.
ALTER TABLE public.walk_answers DROP CONSTRAINT IF EXISTS walk_answers_pkey;
CREATE INDEX IF NOT EXISTS walk_answers_visit_q ON public.walk_answers (visit_id, q);

CREATE OR REPLACE FUNCTION public.walk_answers_for(p_visit_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(jsonb_build_object('q', a.q, 'na', a.na, 'key', a.storage_key, 'note', a.note) ORDER BY a.q, a.at) FROM walk_answers a WHERE a.visit_id = p_visit_id), '[]'::jsonb) END $f$;

-- one answer: N/A (it takes the question's pictures off), or one more picture the app already put in the job-files bucket under
-- forms/<job>/walk-... A second picture for the same question is ADDED, it does not replace the first.
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
  IF p_q IS NULL OR p_q NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'Which question?'; END IF;
  IF coalesce(p_na, false) THEN
    BEGIN   -- the question's pictures leave the customer's file too (hidden, not erased: 299_attachment_delete.sql)
      UPDATE attachments SET deleted_at = now(), deleted_by = public.current_app_user_id()
       WHERE id IN (SELECT attachment_id FROM walk_answers WHERE visit_id = p_visit_id AND q = p_q AND attachment_id IS NOT NULL) AND deleted_at IS NULL;
    EXCEPTION WHEN undefined_column THEN NULL; END;
    DELETE FROM walk_answers WHERE visit_id = p_visit_id AND q = p_q;
    INSERT INTO walk_answers (visit_id, q, question, na, storage_key, attachment_id, at, by_user)
    VALUES (p_visit_id, p_q, left(p_question, 300), true, NULL, NULL, now(), public.current_app_user_id());
    RETURN;
  END IF;
  IF v_key IS NULL OR v_key NOT LIKE 'forms/' || v.job_id || '/walk-%' THEN RAISE EXCEPTION 'Take a picture, or press N/A'; END IF;
  IF EXISTS (SELECT 1 FROM walk_answers WHERE visit_id = p_visit_id AND storage_key = v_key) THEN RETURN; END IF;   -- the save is retried: never twice
  INSERT INTO attachments (entity_type, entity_id, category, file_name, storage_key, mime_type, size_bytes, caption, taken_by_employee_id, taken_at)
  VALUES ('job', v.job_id, 'photo', 'Walk question ' || p_q || '.jpg', v_key, 'image/jpeg', p_size, left('Walk: ' || coalesce(p_question, ''), 400), public.my_employee_id(), now())
  RETURNING id INTO v_att;
  DELETE FROM walk_answers WHERE visit_id = p_visit_id AND q = p_q AND na;
  INSERT INTO walk_answers (visit_id, q, question, na, storage_key, attachment_id, at, by_user)
  VALUES (p_visit_id, p_q, left(p_question, 300), false, v_key, v_att, now(), public.current_app_user_id());
END $function$;

-- take one walk picture off (a numbered question's, or one of the extra ones): it leaves the walk and the customer's file
-- (the photo is hidden, not erased, and a job note says so).
CREATE OR REPLACE FUNCTION public.walk_answer_del(p_visit_id bigint, p_key text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v visits; r walk_answers;
BEGIN
  SELECT * INTO v FROM visits WHERE id = p_visit_id;
  IF v.id IS NULL THEN RAISE EXCEPTION 'That call no longer exists'; END IF;
  IF NOT (public.has_permission('calls.dispatch')
          OR EXISTS (SELECT 1 FROM visit_assignments WHERE visit_id = p_visit_id AND employee_id = public.my_employee_id())) THEN
    RAISE EXCEPTION 'You can only change calls you''re on';
  END IF;
  IF v.status IN ('completed', 'cancelled') THEN RAISE EXCEPTION 'That call is already closed'; END IF;
  SELECT * INTO r FROM walk_answers WHERE visit_id = p_visit_id AND storage_key = nullif(btrim(p_key), '') LIMIT 1;
  IF r.visit_id IS NULL THEN RETURN; END IF;
  IF r.attachment_id IS NOT NULL THEN
    BEGIN UPDATE attachments SET deleted_at = now(), deleted_by = public.current_app_user_id() WHERE id = r.attachment_id AND deleted_at IS NULL;
    EXCEPTION WHEN undefined_column THEN NULL; END;
  END IF;
  DELETE FROM walk_answers WHERE visit_id = p_visit_id AND storage_key = r.storage_key;
  INSERT INTO notes (entity_type, entity_id, body, author_user_id, source)
  VALUES ('job', v.job_id, 'Walk picture deleted' || CASE WHEN r.q < 1000 THEN ' (question ' || r.q || ')' ELSE '' END || '.', public.current_app_user_id(), 'call');
END $function$;
-- a note on one walk picture (Carlo, Nov 14, 3:39 p.m.): kept on the walk, and on the photo's caption in the customer's file.
-- The tech on the call (until it is closed), or dispatch at any time.
CREATE OR REPLACE FUNCTION public.walk_pic_note_set(p_visit_id bigint, p_key text, p_note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v visits; r walk_answers; v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
BEGIN
  SELECT * INTO v FROM visits WHERE id = p_visit_id;
  IF v.id IS NULL THEN RAISE EXCEPTION 'That call no longer exists'; END IF;
  IF NOT public.has_permission('calls.dispatch') THEN
    IF NOT EXISTS (SELECT 1 FROM visit_assignments WHERE visit_id = p_visit_id AND employee_id = public.my_employee_id()) THEN
      RAISE EXCEPTION 'You can only change calls you''re on'; END IF;
    IF v.status IN ('completed', 'cancelled') THEN RAISE EXCEPTION 'That call is already closed'; END IF;
  END IF;
  SELECT * INTO r FROM walk_answers WHERE visit_id = p_visit_id AND storage_key = nullif(btrim(p_key), '') LIMIT 1;
  IF r.visit_id IS NULL THEN RAISE EXCEPTION 'That picture is not on this walk any more'; END IF;
  UPDATE walk_answers SET note = v_note WHERE visit_id = p_visit_id AND storage_key = r.storage_key;
  IF r.attachment_id IS NOT NULL THEN
    UPDATE attachments SET caption = left(regexp_replace(coalesce(caption, ''), '\s*· Note: .*$', '') || coalesce(' · Note: ' || v_note, ''), 900)
     WHERE id = r.attachment_id;
  END IF;
END $function$;
REVOKE EXECUTE ON FUNCTION public.walk_pic_note_set(bigint, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.walk_pic_note_set(bigint, text, text) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.walk_answer_del(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.walk_answer_del(bigint, text) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.walk_questions(), public.set_walk_questions(jsonb), public.walk_answers_for(bigint), public.walk_answer_set(bigint, int, text, boolean, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.walk_questions(), public.set_walk_questions(jsonb), public.walk_answers_for(bigint), public.walk_answer_set(bigint, int, text, boolean, text, bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Carlo, Nov 14, 2026: "add a button to add more pictures without notes in case they need to take more or want to". Besides the numbered walk
-- questions (288_walk_questions.sql), the tech can now add as many extra pictures as they like on a walk, with no question attached. They go
-- in the same walk_answers table, with q 1000 and up (which walk_complete's count ignores, since it only counts q <= the number of questions).
ALTER TABLE public.walk_answers DROP CONSTRAINT IF EXISTS walk_answers_q_check;
ALTER TABLE public.walk_answers ADD CONSTRAINT walk_answers_q_check CHECK (q BETWEEN 1 AND 9999);

-- one more picture, no question: always a new row (q = 1000, 1001, 1002…), never overwritten. Returns the q it was given.
CREATE OR REPLACE FUNCTION public.walk_extra_photo_add(p_visit_id bigint, p_key text, p_size bigint) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v visits; v_att bigint; v_key text := nullif(btrim(p_key), ''); v_q int;
BEGIN
  SELECT * INTO v FROM visits WHERE id = p_visit_id;
  IF v.id IS NULL THEN RAISE EXCEPTION 'That call no longer exists'; END IF;
  IF NOT (public.has_permission('calls.dispatch')
          OR EXISTS (SELECT 1 FROM visit_assignments WHERE visit_id = p_visit_id AND employee_id = public.my_employee_id())) THEN
    RAISE EXCEPTION 'You can only add pictures for calls you''re on';
  END IF;
  IF v.status IN ('completed', 'cancelled') THEN RAISE EXCEPTION 'That call is already closed'; END IF;
  IF v_key IS NULL OR v_key NOT LIKE 'forms/' || v.job_id || '/walk-%' THEN RAISE EXCEPTION 'Take a picture first'; END IF;
  SELECT coalesce(max(q), 999) + 1 INTO v_q FROM walk_answers WHERE visit_id = p_visit_id AND q >= 1000;
  INSERT INTO attachments (entity_type, entity_id, category, file_name, storage_key, mime_type, size_bytes, caption, taken_by_employee_id, taken_at)
  VALUES ('job', v.job_id, 'photo', 'Walk picture.jpg', v_key, 'image/jpeg', p_size, 'Walk: another picture', public.my_employee_id(), now())
  RETURNING id INTO v_att;
  INSERT INTO walk_answers (visit_id, q, question, na, storage_key, attachment_id, at, by_user)
  VALUES (p_visit_id, v_q, 'Another picture', false, v_key, v_att, now(), public.current_app_user_id());
  RETURN v_q;
END $function$;
REVOKE EXECUTE ON FUNCTION public.walk_extra_photo_add(bigint, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.walk_extra_photo_add(bigint, text, bigint) TO authenticated;

-- the extra pictures already saved on a walk (so they still show when the invoice page is opened again)
CREATE OR REPLACE FUNCTION public.walk_extra_photos_for(p_visit_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(jsonb_build_object('q', a.q, 'key', a.storage_key, 'note', a.note) ORDER BY a.q) FROM walk_answers a WHERE a.visit_id = p_visit_id AND a.q >= 1000), '[]'::jsonb) END $f$;
REVOKE EXECUTE ON FUNCTION public.walk_extra_photos_for(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.walk_extra_photos_for(bigint) TO authenticated;

-- walk_to_book (277_walk_done.sql): "answers" is the numbered questions only (q under 1000); the extra pictures, with no question, are "extra"
CREATE OR REPLACE FUNCTION public.walk_to_book() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (public.has_permission('calls.book') OR public.has_permission('calls.dispatch') OR public.current_staff_role() = 'owner') THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x ->> 'done_at') FROM (
    SELECT jsonb_build_object('visit_id', w.visit_id, 'job_id', j.id, 'job_number', j.job_number, 'job_type', t.name, 'what', v.visit_purpose,
      'customer_id', c.id, 'customer', c.display_name, 'address', concat_ws(', ', l.street, 'Unit ' || nullif(btrim(l.unit), ''), l.city),
      'done_at', w.done_at,
      'tech', (SELECT string_agg(public._emp_name(va.employee_id), ' and ' ORDER BY (va.role <> 'lead'), va.id) FROM visit_assignments va WHERE va.visit_id = v.id),
      'pic_notes', (SELECT coalesce(jsonb_object_agg(a.storage_key, a.note), '{}'::jsonb) FROM walk_answers a WHERE a.visit_id = w.visit_id AND a.storage_key IS NOT NULL AND nullif(btrim(a.note), '') IS NOT NULL),
      'answers', (SELECT coalesce(jsonb_agg(jsonb_build_object('q', a.q, 'question', a.question, 'na', a.na, 'key', a.storage_key) ORDER BY a.q), '[]'::jsonb) FROM walk_answers a WHERE a.visit_id = w.visit_id AND a.q < 1000),
      'extra', (SELECT coalesce(jsonb_agg(a.storage_key ORDER BY a.q), '[]'::jsonb) FROM walk_answers a WHERE a.visit_id = w.visit_id AND a.q >= 1000),
      'notes', w.notes, 'signed', w.signature_png IS NOT NULL, 'signer', w.signer_name, 'sig', w.signature_png,
      'invoice', (SELECT i.id FROM invoices i WHERE i.job_id = j.id AND i.status NOT IN ('void', 'draft') AND i.store_copy_of IS NULL ORDER BY i.id LIMIT 1)) AS x
    FROM walk_results w
    JOIN visits v ON v.id = w.visit_id
    JOIN jobs j ON j.id = v.job_id
    JOIN job_types t ON t.id = j.job_type_id
    JOIN customers c ON c.id = j.customer_id
    JOIN locations l ON l.id = j.location_id
    WHERE v.status = 'completed' AND j.status NOT IN ('cancelled', 'closed')
      AND NOT EXISTS (SELECT 1 FROM visits v2 WHERE v2.job_id = j.id AND v2.id > v.id AND v2.status <> 'cancelled')) s), '[]'::jsonb);
END $function$;
REVOKE EXECUTE ON FUNCTION public.walk_to_book() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.walk_to_book() TO authenticated;
NOTIFY pgrst, 'reload schema';

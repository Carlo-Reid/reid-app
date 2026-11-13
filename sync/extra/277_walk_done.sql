-- Nov 13 (Carlo): the tech finishes a walk from the job's own invoice (notes for the walk, the customer can sign, Complete the call),
-- and the call comes back to the office on the To be Booked page under "Walk done: Install date needs to be booked".
CREATE TABLE IF NOT EXISTS public.walk_results (
  visit_id bigint PRIMARY KEY REFERENCES public.visits(id) ON DELETE CASCADE,
  job_id bigint NOT NULL,
  notes text, signer_name text, signature_png text,
  done_at timestamptz NOT NULL DEFAULT now(), done_by bigint);
ALTER TABLE public.walk_results ENABLE ROW LEVEL SECURITY;   -- no policies: only through the functions below
-- Nov 13 (Carlo): the tech answers 4 questions on a walk, each with a picture or N/A; all 4 before the call can be completed (see 288_walk_questions.sql)
CREATE TABLE IF NOT EXISTS public.walk_answers (
  visit_id bigint NOT NULL REFERENCES public.visits(id) ON DELETE CASCADE, q int NOT NULL CHECK (q BETWEEN 1 AND 4),
  question text, na boolean NOT NULL DEFAULT false, storage_key text, attachment_id bigint,
  at timestamptz NOT NULL DEFAULT now(), by_user bigint, PRIMARY KEY (visit_id, q));
ALTER TABLE public.walk_answers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.walk_answers FROM PUBLIC, anon, authenticated;

-- the job's own finished invoice (the one made when the job was sold), so "I'm here" opens it and does not start a second one
CREATE OR REPLACE FUNCTION public.job_invoice(p_job bigint) RETURNS bigint
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  RETURN (SELECT i.id FROM invoices i WHERE i.job_id = p_job AND i.status NOT IN ('void', 'draft') AND i.store_copy_of IS NULL ORDER BY i.id LIMIT 1);
END $function$;
REVOKE EXECUTE ON FUNCTION public.job_invoice(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.job_invoice(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.walk_complete(p_visit_id bigint, p_notes text, p_signer text, p_png text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v visits; v_me bigint := public.current_app_user_id(); v_notes text := nullif(btrim(p_notes), ''); v_png text := nullif(p_png, '');
BEGIN
  SELECT * INTO v FROM visits WHERE id = p_visit_id;
  IF v.id IS NULL THEN RAISE EXCEPTION 'That call no longer exists'; END IF;
  IF NOT (public.has_permission('calls.dispatch')
          OR EXISTS (SELECT 1 FROM visit_assignments WHERE visit_id = p_visit_id AND employee_id = public.my_employee_id())) THEN
    RAISE EXCEPTION 'You can only finish calls you''re on';
  END IF;
  IF v.status IN ('completed', 'cancelled') THEN RAISE EXCEPTION 'That call is already %', CASE v.status WHEN 'completed' THEN 'done' ELSE 'cancelled' END; END IF;
  IF (SELECT count(*) FROM walk_answers a WHERE a.visit_id = p_visit_id AND (a.na OR a.storage_key IS NOT NULL)) < 4 THEN
    RAISE EXCEPTION 'Answer all 4 questions first: a picture, or N/A, for each one';
  END IF;
  IF length(coalesce(v_png, '')) > 400000 THEN RAISE EXCEPTION 'That signature is too big'; END IF;
  IF length(coalesce(v_notes, '')) > 8000 THEN RAISE EXCEPTION 'The notes are too long'; END IF;
  INSERT INTO walk_results (visit_id, job_id, notes, signer_name, signature_png, done_at, done_by)
  VALUES (p_visit_id, v.job_id, v_notes, CASE WHEN v_png IS NULL THEN NULL ELSE nullif(btrim(p_signer), '') END, v_png, now(), v_me)
  ON CONFLICT (visit_id) DO UPDATE SET notes = excluded.notes, signer_name = excluded.signer_name, signature_png = excluded.signature_png, done_at = now(), done_by = excluded.done_by;
  IF v_notes IS NOT NULL THEN   -- kept on the job for the techs; never printed, never sent to the customer
    INSERT INTO notes (entity_type, entity_id, body, author_user_id, source)
    VALUES ('job', v.job_id, 'For the techs (the customer does not see this): Walk notes: ' || v_notes, v_me, 'call');
  END IF;
  PERFORM public.set_call_status(p_visit_id, 'completed', 'Walk done. Install date needs to be booked.');
END $function$;
REVOKE EXECUTE ON FUNCTION public.walk_complete(bigint, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.walk_complete(bigint, text, text, text) TO authenticated;

-- the To be Booked page: walks that are done and whose job has no later call yet
CREATE OR REPLACE FUNCTION public.walk_to_book() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (public.has_permission('calls.book') OR public.has_permission('calls.dispatch') OR public.current_staff_role() = 'owner') THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x ->> 'done_at') FROM (
    SELECT jsonb_build_object('visit_id', w.visit_id, 'job_id', j.id, 'job_number', j.job_number, 'job_type', t.name, 'what', v.visit_purpose,
      'customer_id', c.id, 'customer', c.display_name, 'address', concat_ws(', ', l.street, 'Unit ' || nullif(btrim(l.unit), ''), l.city),
      'done_at', w.done_at,
      'tech', (SELECT string_agg(public._emp_name(va.employee_id), ' and ' ORDER BY (va.role <> 'lead'), va.id) FROM visit_assignments va WHERE va.visit_id = v.id),
      'answers', (SELECT coalesce(jsonb_agg(jsonb_build_object('q', a.q, 'question', a.question, 'na', a.na, 'key', a.storage_key) ORDER BY a.q), '[]'::jsonb) FROM walk_answers a WHERE a.visit_id = w.visit_id),
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

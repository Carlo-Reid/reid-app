-- Sales page: your own notes on a sale, to keep track of changes ("Oct 14 install delayed - wrong equipment ordered").
-- They live with the Costco notes in sale_notes (kind 'note'); a sale is found by its proposal (est_id) or its job (job_id).
ALTER TABLE public.sale_notes ALTER COLUMN est_id DROP NOT NULL;
ALTER TABLE public.sale_notes ADD COLUMN IF NOT EXISTS created_by bigint;
ALTER TABLE public.sale_notes ADD COLUMN IF NOT EXISTS author text;
ALTER TABLE public.sale_notes ADD COLUMN IF NOT EXISTS done boolean NOT NULL DEFAULT false;
ALTER TABLE public.sale_notes ADD COLUMN IF NOT EXISTS updated_at timestamptz;
CREATE INDEX IF NOT EXISTS sale_notes_job ON public.sale_notes (job_id);

CREATE OR REPLACE FUNCTION public.sale_note_add(p_est bigint, p_job bigint, p_body text) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v bigint; v_me bigint := public.current_app_user_id();
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Staff only'; END IF;
  IF coalesce(btrim(p_body), '') = '' THEN RAISE EXCEPTION 'Write the note first'; END IF;
  IF p_est IS NULL AND p_job IS NULL THEN RAISE EXCEPTION 'Which sale?'; END IF;
  INSERT INTO sale_notes (est_id, job_id, body, noted_at, kind, created_by, author)
  VALUES (p_est, p_job, left(btrim(p_body), 2000), now(), 'note', v_me, public._emp_name((SELECT employee_id FROM app_users WHERE id = v_me)))
  RETURNING id INTO v;
  RETURN v;
END $function$;

-- change the words, or mark it done (kept, shown greyed); only the writer or the owner
CREATE OR REPLACE FUNCTION public.sale_note_set(p_id bigint, p_body text DEFAULT NULL, p_done boolean DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM sale_notes WHERE id = p_id AND kind = 'note' AND (created_by = public.current_app_user_id() OR public.current_staff_role() = 'owner')) THEN
    RAISE EXCEPTION 'Only the person who wrote it (or the owner) can change this note'; END IF;
  UPDATE sale_notes SET body = coalesce(nullif(left(btrim(p_body), 2000), ''), body), done = coalesce(p_done, done), updated_at = now() WHERE id = p_id;
END $function$;

CREATE OR REPLACE FUNCTION public.sale_note_del(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM sale_notes WHERE id = p_id AND kind = 'note' AND (created_by = public.current_app_user_id() OR public.current_staff_role() = 'owner')) THEN
    RAISE EXCEPTION 'Only the person who wrote it (or the owner) can delete this note'; END IF;
  DELETE FROM sale_notes WHERE id = p_id;
END $function$;
REVOKE EXECUTE ON FUNCTION public.sale_note_add(bigint, bigint, text), public.sale_note_set(bigint, text, boolean), public.sale_note_del(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sale_note_add(bigint, bigint, text), public.sale_note_set(bigint, text, boolean), public.sale_note_del(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

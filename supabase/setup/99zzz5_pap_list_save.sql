-- =====================================================================
-- Security page: when an owner clicks Mark (an emailed list or a file uploaded by hand), the customer #, name and phone
-- columns of that file are kept, so "People in the EFT files" is built from both. Nothing else from the file is sent.
-- Also: the emailed-lists box says which file each list came from (so it can be opened and its columns picked by hand).
-- Needs 99zz11 and 99zz12. Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.pap_inbox_save(p_id bigint, p_file text, p_list text, p_head jsonb, p_rows jsonb)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id bigint; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF p_list NOT IN ('monthly', 'other') THEN RAISE EXCEPTION 'Pick a list'; END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'No rows'; END IF;
  -- keep only three short text values per row, whatever was sent
  p_rows := (SELECT coalesce(jsonb_agg(jsonb_build_array(left(coalesce(x ->> 0, ''), 60), left(coalesce(x ->> 1, ''), 200), left(coalesce(x ->> 2, ''), 40))), '[]')
             FROM jsonb_array_elements(p_rows) x WHERE jsonb_typeof(x) = 'array');
  IF p_id IS NOT NULL THEN
    UPDATE pap_inbox SET head = p_head, rows = p_rows, pap_list = p_list, note = NULL, status = 'done', done_at = now(), done_by = v_me
    WHERE id = p_id RETURNING id INTO v_id;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO pap_inbox (message_id, received_at, from_name, subject, file_name, pap_list, head, rows, status, done_at, done_by)
    VALUES ('upload:' || gen_random_uuid(), now(), coalesce(public._emp_name((SELECT employee_id FROM app_users WHERE id = v_me)), 'Uploaded'),
            'Uploaded on the Security page', left(coalesce(p_file, 'Uploaded file'), 200), p_list, p_head, p_rows, 'done', now(), v_me)
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.pap_inbox_save(bigint, text, text, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_inbox_save(bigint, text, text, jsonb, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.pap_inbox_list()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE jsonb_build_object(
    'last_check', (SELECT value FROM pap_inbox_state WHERE key = 'last_check'),
    'last_error', (SELECT value FROM pap_inbox_state WHERE key = 'last_error'),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'mail_id', m.mail_id, 'file_id', m.file_id, 'received', m.received_at,
               'from', coalesce(nullif(m.from_name, ''), m.from_addr), 'from_addr', m.from_addr, 'subject', m.subject, 'file', m.file_name,
               'list', m.pap_list, 'head', m.head, 'count', coalesce(jsonb_array_length(m.rows), 0), 'note', m.note, 'status', m.status,
               'upload', m.message_id LIKE 'upload:%', 'done_at', m.done_at,
               'done_by', public._emp_name((SELECT u.employee_id FROM app_users u WHERE u.id = m.done_by)))
             ORDER BY (m.status IN ('waiting', 'unreadable')) DESC, m.received_at DESC NULLS LAST, m.id DESC), '[]')
             FROM (SELECT * FROM pap_inbox WHERE status IN ('waiting', 'unreadable')
                   UNION ALL
                   (SELECT * FROM pap_inbox WHERE status IN ('done', 'ignored') ORDER BY coalesce(done_at, created_at) DESC LIMIT 20)) m)) END
$$;

NOTIFY pgrst, 'reload schema';

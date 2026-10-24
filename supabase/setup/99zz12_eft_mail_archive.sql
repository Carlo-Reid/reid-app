-- =====================================================================
-- Security page: keep every email sent to eftupload@hsginc.ca, with its attachments, so owners can look at
-- them any time. The attachments (the EFT Excel files) have bank details in them, so only owners can see
-- them, and every time someone opens or downloads a file it's written to History. Needs 99zz11.
-- Safe to run more than once.
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.pap_mail (
  id           bigserial PRIMARY KEY,
  message_id   text NOT NULL UNIQUE,
  received_at  timestamptz,
  from_addr    text,
  from_name    text,
  to_addr      text,
  cc_addr      text,
  subject      text,
  body_text    text,
  raw          bytea,             -- the whole email, exactly as it arrived (download as .eml)
  raw_size     integer,
  created_at   timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS pap_mail_received_idx ON public.pap_mail (received_at DESC NULLS LAST, id DESC);
ALTER TABLE public.pap_mail ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_mail FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.pap_mail_file (
  id           bigserial PRIMARY KEY,
  mail_id      bigint NOT NULL REFERENCES public.pap_mail(id) ON DELETE CASCADE,
  file_name    text,
  mime         text,
  size         integer,
  data         bytea);
CREATE INDEX IF NOT EXISTS pap_mail_file_mail_idx ON public.pap_mail_file (mail_id);
ALTER TABLE public.pap_mail_file ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_mail_file FROM anon, authenticated;

-- each emailed list points back to its email and file
ALTER TABLE public.pap_inbox ADD COLUMN IF NOT EXISTS mail_id bigint REFERENCES public.pap_mail(id) ON DELETE SET NULL;
ALTER TABLE public.pap_inbox ADD COLUMN IF NOT EXISTS file_id bigint REFERENCES public.pap_mail_file(id) ON DELETE SET NULL;

-- All the emails (owners only), newest first; p_q looks in sender, subject, words and file names
CREATE OR REPLACE FUNCTION public.pap_mail_list(p_q text DEFAULT NULL, p_limit integer DEFAULT 200)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE jsonb_build_object(
    'total', (SELECT count(*) FROM pap_mail),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'received', m.received_at, 'from', coalesce(nullif(m.from_name, ''), m.from_addr),
               'from_addr', m.from_addr, 'subject', m.subject,
               'files', (SELECT coalesce(jsonb_agg(f.file_name ORDER BY f.id), '[]') FROM pap_mail_file f WHERE f.mail_id = m.id),
               'list_status', (SELECT string_agg(DISTINCT i.status, ',') FROM pap_inbox i WHERE i.mail_id = m.id))
             ORDER BY m.received_at DESC NULLS LAST, m.id DESC), '[]')
             FROM (SELECT * FROM pap_mail x
                   WHERE nullif(btrim(p_q), '') IS NULL
                      OR concat_ws(' ', x.from_name, x.from_addr, x.subject, x.body_text,
                                   (SELECT string_agg(f.file_name, ' ') FROM pap_mail_file f WHERE f.mail_id = x.id)) ILIKE '%' || btrim(p_q) || '%'
                   ORDER BY x.received_at DESC NULLS LAST, x.id DESC LIMIT least(coalesce(p_limit, 200), 1000)) m)) END
$$;

-- One email: who, when, the words, and its attachments (names and sizes, not the files)
CREATE OR REPLACE FUNCTION public.pap_mail_get(p_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE
    (SELECT jsonb_build_object('id', m.id, 'received', m.received_at, 'from_name', m.from_name, 'from_addr', m.from_addr,
              'to', m.to_addr, 'cc', m.cc_addr, 'subject', m.subject, 'body', m.body_text, 'raw_size', m.raw_size,
              'files', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'name', f.file_name, 'mime', f.mime, 'size', f.size) ORDER BY f.id), '[]')
                        FROM pap_mail_file f WHERE f.mail_id = m.id))
     FROM pap_mail m WHERE m.id = p_id) END
$$;

-- Open / download an attachment (or, with p_raw, the whole email). Written to History, since these files hold bank details.
CREATE OR REPLACE FUNCTION public.pap_mail_file(p_id bigint, p_raw boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF p_raw THEN
    SELECT jsonb_build_object('name', coalesce(nullif(regexp_replace(coalesce(subject, ''), '[^A-Za-z0-9 _.-]+', '', 'g'), ''), 'email') || '.eml',
                              'mime', 'message/rfc822', 'b64', encode(raw, 'base64'))
      INTO r FROM pap_mail WHERE id = p_id AND raw IS NOT NULL;
  ELSE
    SELECT jsonb_build_object('name', file_name, 'mime', mime, 'b64', encode(data, 'base64')) INTO r FROM pap_mail_file WHERE id = p_id;
  END IF;
  IF r IS NOT NULL THEN
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
    VALUES (CASE WHEN p_raw THEN 'pap_mail' ELSE 'pap_mail_file' END, p_id, 'update', public.current_app_user_id(),
            jsonb_build_object('change', 'opened EFT email ' || CASE WHEN p_raw THEN 'message' ELSE 'file' END, 'file', r ->> 'name'));
  END IF;
  RETURN r;
END $$;

-- Emailed lists now keep their rows after they're marked or ignored (so you can look back at them)
CREATE OR REPLACE FUNCTION public.pap_inbox_set(p_id bigint, p_status text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF p_status NOT IN ('done', 'ignored', 'waiting') THEN RAISE EXCEPTION 'Unknown status'; END IF;
  UPDATE pap_inbox SET status = p_status,
         done_at = CASE WHEN p_status = 'waiting' THEN NULL ELSE now() END,
         done_by = CASE WHEN p_status = 'waiting' THEN NULL ELSE public.current_app_user_id() END
  WHERE id = p_id AND (p_status <> 'waiting' OR rows IS NOT NULL);
END $$;

-- the emailed-lists box also gets the email each list came from
CREATE OR REPLACE FUNCTION public.pap_inbox_list()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE jsonb_build_object(
    'last_check', (SELECT value FROM pap_inbox_state WHERE key = 'last_check'),
    'last_error', (SELECT value FROM pap_inbox_state WHERE key = 'last_error'),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'mail_id', m.mail_id, 'received', m.received_at, 'from', coalesce(nullif(m.from_name, ''), m.from_addr),
               'from_addr', m.from_addr, 'subject', m.subject, 'file', m.file_name, 'list', m.pap_list, 'head', m.head,
               'count', coalesce(jsonb_array_length(m.rows), 0), 'note', m.note, 'status', m.status, 'done_at', m.done_at,
               'done_by', public._emp_name((SELECT u.employee_id FROM app_users u WHERE u.id = m.done_by)))
             ORDER BY (m.status IN ('waiting', 'unreadable')) DESC, m.received_at DESC NULLS LAST, m.id DESC), '[]')
             FROM (SELECT * FROM pap_inbox WHERE status IN ('waiting', 'unreadable')
                   UNION ALL
                   (SELECT * FROM pap_inbox WHERE status IN ('done', 'ignored') ORDER BY coalesce(done_at, created_at) DESC LIMIT 20)) m)) END
$$;

REVOKE EXECUTE ON FUNCTION public.pap_mail_list(text, integer), public.pap_mail_get(bigint), public.pap_mail_file(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_mail_list(text, integer), public.pap_mail_get(bigint), public.pap_mail_file(bigint, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';

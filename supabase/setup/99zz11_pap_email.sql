-- =====================================================================
-- Security page: EFT / PAP lists by email. A job on GitHub checks eftupload@hsginc.ca every 10 minutes.
-- For each Excel (or CSV) attachment it keeps ONLY the customer #, name and phone columns; the file itself,
-- bank details and every other column are never saved. The list waits on the Security page until an owner
-- reviews it and clicks Mark; nothing changes on its own. Needs 99zz. Safe to run more than once.
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.pap_inbox (
  id           bigserial PRIMARY KEY,
  message_id   text NOT NULL,
  received_at  timestamptz,
  from_addr    text,
  from_name    text,
  subject      text,
  file_name    text,
  pap_list     text NOT NULL DEFAULT 'monthly' CHECK (pap_list IN ('monthly', 'other')),
  head         jsonb,             -- the three column names found in the file: [customer #, name, phone]
  rows         jsonb,             -- [[customer #, name, phone], ...] only
  note         text,              -- why it couldn't be read, if it couldn't
  status       text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'done', 'ignored', 'unreadable')),
  done_at      timestamptz,
  done_by      bigint,
  created_at   timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX IF NOT EXISTS pap_inbox_file_key ON public.pap_inbox (message_id, coalesce(file_name, ''));
CREATE INDEX IF NOT EXISTS pap_inbox_status_idx ON public.pap_inbox (status, received_at DESC);
ALTER TABLE public.pap_inbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_inbox FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.pap_inbox_seen (message_id text PRIMARY KEY, seen_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.pap_inbox_seen ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_inbox_seen FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.pap_inbox_state (key text PRIMARY KEY, value text, updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.pap_inbox_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_inbox_state FROM anon, authenticated;

-- What's in the EFT mailbox (owners only): the lists waiting, plus the last 20 handled
CREATE OR REPLACE FUNCTION public.pap_inbox_list()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE jsonb_build_object(
    'last_check', (SELECT value FROM pap_inbox_state WHERE key = 'last_check'),
    'last_error', (SELECT value FROM pap_inbox_state WHERE key = 'last_error'),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'received', m.received_at, 'from', coalesce(nullif(m.from_name, ''), m.from_addr),
               'from_addr', m.from_addr, 'subject', m.subject, 'file', m.file_name, 'list', m.pap_list, 'head', m.head,
               'count', coalesce(jsonb_array_length(m.rows), 0), 'note', m.note, 'status', m.status, 'done_at', m.done_at,
               'done_by', public._emp_name((SELECT u.employee_id FROM app_users u WHERE u.id = m.done_by)))
             ORDER BY (m.status IN ('waiting', 'unreadable')) DESC, m.received_at DESC NULLS LAST, m.id DESC), '[]')
             FROM (SELECT * FROM pap_inbox WHERE status IN ('waiting', 'unreadable')
                   UNION ALL
                   (SELECT * FROM pap_inbox WHERE status IN ('done', 'ignored') ORDER BY coalesce(done_at, created_at) DESC LIMIT 20)) m)) END
$$;

-- The rows of one emailed list (only the three columns), to review and match
CREATE OR REPLACE FUNCTION public.pap_inbox_rows(p_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE
    (SELECT jsonb_build_object('file', file_name, 'list', pap_list, 'head', head, 'rows', coalesce(rows, '[]')) FROM pap_inbox WHERE id = p_id) END
$$;

-- Mark an emailed list as done (after Mark) or ignored. Once handled, its rows are cleared: they aren't needed any more.
CREATE OR REPLACE FUNCTION public.pap_inbox_set(p_id bigint, p_status text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF p_status NOT IN ('done', 'ignored', 'waiting') THEN RAISE EXCEPTION 'Unknown status'; END IF;
  UPDATE pap_inbox SET status = p_status,
         done_at = CASE WHEN p_status = 'waiting' THEN NULL ELSE now() END,
         done_by = CASE WHEN p_status = 'waiting' THEN NULL ELSE public.current_app_user_id() END,
         rows = CASE WHEN p_status = 'waiting' THEN rows ELSE NULL END
  WHERE id = p_id AND (p_status <> 'waiting' OR rows IS NOT NULL);
END $$;

REVOKE EXECUTE ON FUNCTION public.pap_inbox_list(), public.pap_inbox_rows(bigint), public.pap_inbox_set(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_inbox_list(), public.pap_inbox_rows(bigint), public.pap_inbox_set(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- Send anything to a customer (estimates, invoices, and any other document later): by email and/or text,
-- as a link to view it, or a link plus the PDF (attached to an email, or a second link in a text).
-- Every send is kept: what, who, when, to whom, how, and when it's opened and viewed. Each time a link is used
-- is written down too (time, device, network), for the open / forward tracking.
-- TEST MODE (on to start): emails go to company_settings.send_test_to (carlo@homeservicegroup.ca) and texts go to
-- the cell phone on the sender's own employee record. Empty send_test_to to go live.
-- Sending is done by the "send-doc" function in Supabase; the links by "doc-open".
-- Needs 99h (invoice emails). Safe to run more than once.
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'company_settings' AND column_name = 'send_test_to') THEN
    ALTER TABLE public.company_settings ADD COLUMN send_test_to text;
    UPDATE public.company_settings SET send_test_to = 'carlo@homeservicegroup.ca';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.doc_sends (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind          text NOT NULL,          -- estimate, invoice, or anything else
  ref_id        bigint,                 -- the estimate / invoice id
  title         text,                   -- "Estimate E10000000003"
  customer_id   bigint REFERENCES public.customers(id),
  channel       text NOT NULL CHECK (channel IN ('email', 'text')),
  to_address    text NOT NULL,          -- who it was meant for (email or phone)
  sent_to       text NOT NULL,          -- where it actually went (you, while testing)
  test          boolean NOT NULL DEFAULT false,
  subject       text,
  body          text NOT NULL,
  with_pdf      boolean NOT NULL DEFAULT false,
  pdf           bytea,
  file_name     text,
  token         uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  status        text NOT NULL DEFAULT 'sending' CHECK (status IN ('sending', 'sent', 'failed')),
  error         text,
  sent_by       bigint REFERENCES public.app_users(id),
  sent_at       timestamptz NOT NULL DEFAULT now(),
  opened_at timestamptz, last_opened_at timestamptz, open_count int NOT NULL DEFAULT 0,
  viewed_at timestamptz, last_viewed_at timestamptz, view_count int NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS doc_sends_ref_idx ON public.doc_sends (kind, ref_id, sent_at DESC);
CREATE INDEX IF NOT EXISTS doc_sends_customer_idx ON public.doc_sends (customer_id, sent_at DESC);
ALTER TABLE public.doc_sends ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.doc_sends FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.doc_send_hits (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  send_id     bigint NOT NULL REFERENCES public.doc_sends(id) ON DELETE CASCADE,
  kind        text NOT NULL,            -- open (the picture in an email), view, pdf
  at          timestamptz NOT NULL DEFAULT now(),
  ip          text,
  user_agent  text,
  info        jsonb);
CREATE INDEX IF NOT EXISTS doc_send_hits_send_idx ON public.doc_send_hits (send_id, at);
ALTER TABLE public.doc_send_hits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.doc_send_hits FROM anon, authenticated;

-- whose document it is: the estimate's / invoice's customer, else the customer given
CREATE OR REPLACE FUNCTION public._doc_customer(p_kind text, p_ref bigint, p_customer bigint) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(CASE p_kind WHEN 'estimate' THEN (SELECT customer_id FROM estimates WHERE id = p_ref)
                              WHEN 'invoice'  THEN (SELECT customer_id FROM invoices WHERE id = p_ref) END, p_customer)
$$;

-- Who it can go to: every email and phone on the customer's file (and the partner's billing email), and past sends of this document
CREATE OR REPLACE FUNCTION public.doc_send_info(p_kind text, p_ref bigint, p_customer bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH c AS (SELECT public._doc_customer(p_kind, p_ref, p_customer) AS id)
  SELECT CASE WHEN NOT public.has_permission('email.send') THEN NULL ELSE jsonb_build_object(
    'customer_id', (SELECT id FROM c),
    'customer_name', (SELECT display_name FROM customers WHERE id = (SELECT id FROM c)),
    'emails', (SELECT coalesce(jsonb_agg(x ORDER BY (x->>'pri')::boolean DESC, (x->>'id')::bigint), '[]') FROM (
                 SELECT DISTINCT ON (lower(btrim(cc.value))) jsonb_build_object('id', cc.id, 'value', lower(btrim(cc.value)), 'name', cc.contact_name, 'pri', cc.is_primary) AS x
                 FROM customer_contacts cc WHERE cc.customer_id = (SELECT id FROM c) AND cc.kind = 'email' AND btrim(cc.value) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
                 ORDER BY lower(btrim(cc.value)), cc.is_primary DESC, cc.id) t),
    'phones', (SELECT coalesce(jsonb_agg(x ORDER BY (x->>'mob')::boolean DESC, (x->>'pri')::boolean DESC, (x->>'id')::bigint), '[]') FROM (
                 SELECT DISTINCT ON (right(regexp_replace(cc.value, '\D', '', 'g'), 10)) jsonb_build_object('id', cc.id, 'value', right(regexp_replace(cc.value, '\D', '', 'g'), 10),
                          'kind', cc.kind, 'name', cc.contact_name, 'pri', cc.is_primary, 'mob', cc.kind = 'mobile') AS x
                 FROM customer_contacts cc WHERE cc.customer_id = (SELECT id FROM c) AND cc.kind IN ('mobile', 'phone') AND length(regexp_replace(cc.value, '\D', '', 'g')) >= 10
                 ORDER BY right(regexp_replace(cc.value, '\D', '', 'g'), 10), (cc.kind = 'mobile') DESC, cc.is_primary DESC, cc.id) t),
    'partner_email', CASE p_kind
       WHEN 'invoice'  THEN (SELECT jsonb_build_object('name', p.name, 'value', lower(p.billing_email::text)) FROM invoices i JOIN partners p ON p.id = i.bill_to_partner_id
                             WHERE i.id = p_ref AND p.bill_to_ok AND p.billing_email IS NOT NULL)
       WHEN 'estimate' THEN (SELECT jsonb_build_object('name', p.name, 'value', lower(p.billing_email::text)) FROM estimates e JOIN jobs j ON j.id = e.job_id JOIN partners p ON p.id = j.partner_id
                             WHERE e.id = p_ref AND p.billing_email IS NOT NULL) END,
    'test_to', (SELECT nullif(btrim(send_test_to), '') FROM company_settings ORDER BY id LIMIT 1),
    'my_cell', (SELECT nullif(right(regexp_replace(coalesce(em.mobile_phone, ''), '\D', '', 'g'), 10), '') FROM app_users u JOIN employees em ON em.id = u.employee_id WHERE u.id = public.current_app_user_id()),
    'sends', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'channel', s.channel, 'to', s.to_address, 'sent_to', s.sent_to, 'test', s.test, 'with_pdf', s.with_pdf,
                'status', s.status, 'error', s.error, 'sent_at', s.sent_at, 'by', public._staff_name(s.sent_by), 'opened_at', s.opened_at, 'last_opened_at', s.last_opened_at,
                'open_count', s.open_count, 'viewed_at', s.viewed_at, 'last_viewed_at', s.last_viewed_at, 'view_count', s.view_count) ORDER BY s.sent_at DESC), '[]')
              FROM doc_sends s WHERE s.kind = p_kind AND s.ref_id IS NOT DISTINCT FROM p_ref AND (p_ref IS NOT NULL OR s.customer_id = (SELECT id FROM c)))) END
$$;

-- Called by send-doc (as the person sending): checks, picks where it really goes, keeps a copy. Returns {id, token, send_to, test}
CREATE OR REPLACE FUNCTION public.doc_send_start(p_kind text, p_ref bigint, p_customer bigint, p_title text, p_channel text, p_to text, p_subject text, p_body text,
                                                 p_with_pdf boolean, p_pdf_b64 text, p_file_name text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_test text; v_to text; v_send text; v_cust bigint; r doc_sends;
BEGIN
  IF NOT public.has_permission('email.send') THEN RAISE EXCEPTION 'You don''t have permission to send to customers'; END IF;
  IF p_channel NOT IN ('email', 'text') THEN RAISE EXCEPTION 'Email or text?'; END IF;
  IF p_kind = 'estimate' AND NOT EXISTS (SELECT 1 FROM estimates WHERE id = p_ref) THEN RAISE EXCEPTION 'That estimate no longer exists'; END IF;
  IF p_kind = 'invoice' AND NOT EXISTS (SELECT 1 FROM invoices WHERE id = p_ref) THEN RAISE EXCEPTION 'That invoice no longer exists'; END IF;
  v_cust := public._doc_customer(p_kind, p_ref, p_customer);
  SELECT nullif(btrim(send_test_to), '') INTO v_test FROM company_settings ORDER BY id LIMIT 1;
  IF p_channel = 'email' THEN
    v_to := lower(btrim(coalesce(p_to, '')));
    IF v_to !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN RAISE EXCEPTION 'That email address doesn''t look right: %', p_to; END IF;
    v_send := coalesce(lower(v_test), v_to);
  ELSE
    v_to := right(regexp_replace(coalesce(p_to, ''), '\D', '', 'g'), 10);
    IF length(v_to) <> 10 THEN RAISE EXCEPTION 'That phone number doesn''t look right: %', p_to; END IF;
    IF v_test IS NOT NULL THEN   -- test mode: the text goes to the sender's own cell
      SELECT right(regexp_replace(coalesce(em.mobile_phone, ''), '\D', '', 'g'), 10) INTO v_send FROM app_users u JOIN employees em ON em.id = u.employee_id WHERE u.id = public.current_app_user_id();
      IF coalesce(length(v_send), 0) <> 10 THEN RAISE EXCEPTION 'Test mode sends texts to your own cell, and there isn''t one on your employee record. Add it there first.'; END IF;
    ELSE v_send := v_to; END IF;
  END IF;
  INSERT INTO doc_sends (kind, ref_id, title, customer_id, channel, to_address, sent_to, test, subject, body, with_pdf, pdf, file_name, sent_by)
  VALUES (left(coalesce(nullif(btrim(p_kind), ''), 'other'), 40), p_ref, left(p_title, 200), v_cust, p_channel, v_to, v_send, v_test IS NOT NULL,
          left(btrim(coalesce(p_subject, '')), 300), left(coalesce(p_body, ''), 20000), coalesce(p_with_pdf, false),
          CASE WHEN nullif(p_pdf_b64, '') IS NOT NULL THEN decode(p_pdf_b64, 'base64') END, left(coalesce(p_file_name, 'document.pdf'), 120), public.current_app_user_id())
  RETURNING * INTO r;
  RETURN jsonb_build_object('id', r.id, 'token', r.token, 'send_to', r.sent_to, 'test', r.test, 'customer_id', r.customer_id);
END $$;

-- Called by send-doc after trying to send
CREATE OR REPLACE FUNCTION public.doc_send_done(p_id bigint, p_ok boolean, p_error text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r doc_sends;
BEGIN
  IF NOT public.has_permission('email.send') THEN RAISE EXCEPTION 'You don''t have permission to send to customers'; END IF;
  UPDATE doc_sends SET status = CASE WHEN p_ok THEN 'sent' ELSE 'failed' END, error = left(p_error, 500) WHERE id = p_id RETURNING * INTO r;
  IF p_ok AND r.id IS NOT NULL THEN
    IF r.channel = 'email' AND r.customer_id IS NOT NULL THEN   -- a copy on the customer's file (Emails), like any other email
      INSERT INTO customer_emails (customer_id, to_address, subject, body, sent_by_user_id, status)
      VALUES (r.customer_id, r.sent_to, r.subject || CASE WHEN r.test THEN ' [test: meant for ' || r.to_address || ']' ELSE '' END, r.body, r.sent_by, 'sent');
    END IF;
    IF NOT r.test THEN
      IF r.kind = 'estimate' THEN UPDATE estimates SET status = CASE WHEN status = 'draft' THEN 'sent' ELSE status END, sent_at = coalesce(sent_at, now()) WHERE id = r.ref_id; END IF;
      IF r.kind = 'invoice' THEN UPDATE invoices SET sent_at = coalesce(sent_at, now()) WHERE id = r.ref_id; END IF;
    END IF;
  END IF;
END $$;

-- Called by doc-open (no sign-in: the secret link). p_kind: open (the picture in an email), view, pdf.
-- Writes the visit down; returns what the page needs (and the PDF for view / pdf).
CREATE OR REPLACE FUNCTION public.doc_send_hit(p_token uuid, p_kind text, p_ip text DEFAULT NULL, p_ua text DEFAULT NULL, p_info jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r doc_sends; k text := CASE WHEN p_kind IN ('view', 'pdf') THEN p_kind ELSE 'open' END;
BEGIN
  IF k IN ('view', 'pdf') THEN
    UPDATE doc_sends SET viewed_at = coalesce(viewed_at, now()), last_viewed_at = now(), view_count = view_count + 1,
           opened_at = coalesce(opened_at, now()), last_opened_at = now(), open_count = greatest(open_count, 1)
    WHERE token = p_token RETURNING * INTO r;
  ELSE
    UPDATE doc_sends SET opened_at = coalesce(opened_at, now()), last_opened_at = now(), open_count = open_count + 1 WHERE token = p_token RETURNING * INTO r;
  END IF;
  IF r.id IS NULL THEN RETURN NULL; END IF;
  INSERT INTO doc_send_hits (send_id, kind, ip, user_agent, info) VALUES (r.id, k, left(p_ip, 100), left(p_ua, 500), p_info);
  RETURN jsonb_build_object('kind', r.kind, 'title', r.title, 'file_name', r.file_name, 'pdf', CASE WHEN k IN ('view', 'pdf') THEN encode(r.pdf, 'base64') END);
END $$;

REVOKE EXECUTE ON FUNCTION public._doc_customer(text, bigint, bigint), public.doc_send_info(text, bigint, bigint),
  public.doc_send_start(text, bigint, bigint, text, text, text, text, text, boolean, text, text),
  public.doc_send_done(bigint, boolean, text), public.doc_send_hit(uuid, text, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.doc_send_info(text, bigint, bigint), public.doc_send_start(text, bigint, bigint, text, text, text, text, text, boolean, text, text),
  public.doc_send_done(bigint, boolean, text) TO authenticated;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN GRANT EXECUTE ON FUNCTION public.doc_send_hit(uuid, text, text, text, jsonb) TO service_role; END IF; END $$;

NOTIFY pgrst, 'reload schema';

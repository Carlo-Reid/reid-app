-- Run 99zzzF again: re-running 99zzzE on Oct 26 put back older doc_send_hit / doc_send_info
-- =====================================================================
-- Tracking for anything sent with send-doc (estimates, invoices…):
--   * Every time a link is opened, the page asks first: "Do you want to view this estimate?" and who they are
--     ("it was sent to me" / "it was forwarded to me" + their name and who sent it). Each answer is kept.
--   * Forwards are flagged: when someone says it was forwarded (forwarded), or when a new device on a new network
--     opens it after the first one (maybe_forwarded).
--   * The rough place (city / region from the network) and the device are kept with each visit.
--   * doc_send_track: the visit history of one send.  doc_send_list: everything sent, for the Sent page.
-- Needs 99zzzE. Safe to run more than once.
-- =====================================================================
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'doc_sends' AND column_name = 'forwarded') THEN
    ALTER TABLE public.doc_sends ADD COLUMN forwarded boolean NOT NULL DEFAULT false,
                                 ADD COLUMN maybe_forwarded boolean NOT NULL DEFAULT false,
                                 ADD COLUMN devices int NOT NULL DEFAULT 0,
                                 ADD COLUMN declined_at timestamptz;
  END IF;
END $$;

-- the network a visit came from, roughly (the first three parts of the address): the same phone on the same Wi-Fi stays the same
CREATE OR REPLACE FUNCTION public._net(p_ip text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_ip ~ '^\d+\.\d+\.\d+\.\d+$' THEN substring(p_ip from '^(\d+\.\d+\.\d+)\.')
              WHEN p_ip LIKE '%:%' THEN array_to_string((string_to_array(p_ip, ':'))[1:3], ':') ELSE coalesce(p_ip, '') END
$$;

-- Called by doc-open (no sign-in: the secret link).
--   p_kind: open (the picture in an email), ask (the "do you want to view it?" page), view / pdf (they said yes), no (they said no)
--   p_info: what the page knows: who (me / forwarded), name, from, geo {city, region, country, org}, lang…
CREATE OR REPLACE FUNCTION public.doc_send_hit(p_token uuid, p_kind text, p_ip text DEFAULT NULL, p_ua text DEFAULT NULL, p_info jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r doc_sends; k text := CASE WHEN p_kind IN ('view', 'pdf', 'ask', 'no') THEN p_kind ELSE 'open' END; v_new boolean; v_sent_on text;
BEGIN
  SELECT * INTO r FROM doc_sends WHERE token = p_token;
  IF r.id IS NULL THEN RETURN NULL; END IF;
  -- a new person? a device we haven't seen, on a network we haven't seen, after someone already opened it (the email picture doesn't count:
  -- mail apps fetch it from their own servers)
  v_new := k IN ('ask', 'view', 'pdf') AND EXISTS (SELECT 1 FROM doc_send_hits h WHERE h.send_id = r.id AND h.kind IN ('ask', 'view', 'pdf'))
           AND NOT EXISTS (SELECT 1 FROM doc_send_hits h WHERE h.send_id = r.id AND h.kind IN ('ask', 'view', 'pdf')
                           AND (coalesce(h.user_agent, '') = coalesce(p_ua, '') OR public._net(h.ip) = public._net(p_ip)));
  INSERT INTO doc_send_hits (send_id, kind, ip, user_agent, info) VALUES (r.id, k, left(p_ip, 100), left(p_ua, 500), p_info);
  UPDATE doc_sends SET
    opened_at = coalesce(opened_at, now()), last_opened_at = now(),
    open_count = open_count + CASE WHEN k = 'open' THEN 1 ELSE 0 END + CASE WHEN k <> 'open' AND open_count = 0 THEN 1 ELSE 0 END,
    viewed_at = CASE WHEN k IN ('view', 'pdf') THEN coalesce(viewed_at, now()) ELSE viewed_at END,
    last_viewed_at = CASE WHEN k IN ('view', 'pdf') THEN now() ELSE last_viewed_at END,
    view_count = view_count + CASE WHEN k IN ('view', 'pdf') THEN 1 ELSE 0 END,
    declined_at = CASE WHEN k = 'no' THEN now() ELSE declined_at END,
    forwarded = forwarded OR coalesce(p_info ->> 'who', '') = 'forwarded',
    maybe_forwarded = maybe_forwarded OR v_new,
    devices = (SELECT count(DISTINCT coalesce(h.user_agent, '')) FROM doc_send_hits h WHERE h.send_id = r.id AND h.kind IN ('ask', 'view', 'pdf'))
  WHERE id = r.id RETURNING * INTO r;
  SELECT to_char(r.sent_at AT TIME ZONE 'America/Toronto', 'FMMonth FMDD, YYYY') INTO v_sent_on;
  RETURN jsonb_build_object('kind', r.kind, 'title', r.title, 'file_name', r.file_name, 'sent_on', v_sent_on, 'has_pdf', r.pdf IS NOT NULL,
                            'pdf', CASE WHEN k IN ('view', 'pdf') THEN encode(r.pdf, 'base64') END);
END $$;

-- The visit history of one send (for the sending panel)
CREATE OR REPLACE FUNCTION public.doc_send_track(p_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public.has_permission('email.send'), false) THEN NULL ELSE
    (SELECT jsonb_build_object('id', s.id, 'forwarded', s.forwarded, 'maybe_forwarded', s.maybe_forwarded, 'devices', s.devices, 'declined_at', s.declined_at,
       'hits', (SELECT coalesce(jsonb_agg(jsonb_build_object('at', h.at, 'kind', h.kind, 'ua', h.user_agent, 'net', public._net(h.ip),
                  'who', h.info ->> 'who', 'name', h.info ->> 'name', 'from', h.info ->> 'from', 'geo', h.info -> 'geo') ORDER BY h.at), '[]')
                FROM doc_send_hits h WHERE h.send_id = s.id))
     FROM doc_sends s WHERE s.id = p_id) END
$$;

-- Everything sent (newest first), for the Sent page. p_show: all, unopened, opened, viewed, forwarded, failed
CREATE OR REPLACE FUNCTION public.doc_send_list(p_show text DEFAULT 'all', p_q text DEFAULT NULL, p_days integer DEFAULT 90, p_limit integer DEFAULT 300)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH s AS (
    SELECT s.*, c.display_name AS customer_name
    FROM doc_sends s LEFT JOIN customers c ON c.id = s.customer_id
    WHERE s.sent_at > now() - make_interval(days => least(greatest(coalesce(p_days, 90), 1), 3650))
      AND (nullif(btrim(p_q), '') IS NULL OR concat_ws(' ', c.display_name, s.title, s.to_address, s.sent_to, s.subject) ILIKE '%' || btrim(p_q) || '%'))
  SELECT CASE WHEN NOT coalesce(public.has_permission('email.send'), false) THEN NULL ELSE jsonb_build_object(
    'counts', jsonb_build_object('all', (SELECT count(*) FROM s), 'unopened', (SELECT count(*) FROM s WHERE status = 'sent' AND opened_at IS NULL),
       'opened', (SELECT count(*) FROM s WHERE opened_at IS NOT NULL), 'viewed', (SELECT count(*) FROM s WHERE viewed_at IS NOT NULL),
       'forwarded', (SELECT count(*) FROM s WHERE forwarded OR maybe_forwarded), 'failed', (SELECT count(*) FROM s WHERE status = 'failed')),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'ref_id', x.ref_id, 'title', x.title, 'customer_id', x.customer_id, 'customer_name', x.customer_name,
               'channel', x.channel, 'to', x.to_address, 'sent_to', x.sent_to, 'test', x.test, 'with_pdf', x.with_pdf, 'status', x.status, 'error', x.error,
               'sent_at', x.sent_at, 'by', public._staff_name(x.sent_by), 'opened_at', x.opened_at, 'last_opened_at', x.last_opened_at, 'open_count', x.open_count,
               'viewed_at', x.viewed_at, 'last_viewed_at', x.last_viewed_at, 'view_count', x.view_count, 'forwarded', x.forwarded, 'maybe_forwarded', x.maybe_forwarded,
               'devices', x.devices, 'declined_at', x.declined_at) ORDER BY x.sent_at DESC), '[]')
             FROM (SELECT * FROM s WHERE CASE coalesce(p_show, 'all')
                     WHEN 'unopened' THEN status = 'sent' AND opened_at IS NULL WHEN 'opened' THEN opened_at IS NOT NULL
                     WHEN 'viewed' THEN viewed_at IS NOT NULL WHEN 'forwarded' THEN forwarded OR maybe_forwarded WHEN 'failed' THEN status = 'failed' ELSE true END
                   ORDER BY sent_at DESC LIMIT least(coalesce(p_limit, 300), 1000)) x)) END
$$;

-- the sending panel's list also says if it was forwarded and on how many devices
CREATE OR REPLACE FUNCTION public.doc_send_info(p_kind text, p_ref bigint, p_customer bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH c AS (SELECT public._doc_customer(p_kind, p_ref, p_customer) AS id)
  SELECT CASE WHEN NOT coalesce(public.has_permission('email.send'), false) THEN NULL ELSE jsonb_build_object(
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
                'open_count', s.open_count, 'viewed_at', s.viewed_at, 'last_viewed_at', s.last_viewed_at, 'view_count', s.view_count,
                'forwarded', s.forwarded, 'maybe_forwarded', s.maybe_forwarded, 'devices', s.devices, 'declined_at', s.declined_at) ORDER BY s.sent_at DESC), '[]')
              FROM doc_sends s WHERE s.kind = p_kind AND s.ref_id IS NOT DISTINCT FROM p_ref AND (p_ref IS NOT NULL OR s.customer_id = (SELECT id FROM c)))) END
$$;

REVOKE EXECUTE ON FUNCTION public.doc_send_track(bigint), public.doc_send_list(text, text, integer, integer), public.doc_send_hit(uuid, text, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.doc_send_track(bigint), public.doc_send_list(text, text, integer, integer) TO authenticated;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN GRANT EXECUTE ON FUNCTION public.doc_send_hit(uuid, text, text, text, jsonb) TO service_role; END IF; END $$;

NOTIFY pgrst, 'reload schema';

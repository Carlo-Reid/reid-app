-- Podium live (Carlo, Nov 10: "yes do it all"): texts sent from the app through Podium, and every call and text coming in by itself.
-- Podium tells the app the moment something happens (a "webhook" to the podium-hook Edge Function, signed with a shared secret kept in
-- the vault); the app keeps its own copy in podium_calls and podium_messages, tied to customers by phone number. Texts are sent by the
-- podium Edge Function (action "send"). Office people and owners only (_rec_ok, from 247). Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.podium_calls (uid text PRIMARY KEY, event text, direction text, phone text, location_phone text, started_at timestamptz, ended_at timestamptz,
  duration_s int, has_voicemail boolean, voicemail jsonb, details_url text, customer_ids bigint[] NOT NULL DEFAULT '{}', user_uid text, raw jsonb,
  at timestamptz NOT NULL DEFAULT now(), handled_at timestamptz, handled_by bigint);
CREATE INDEX IF NOT EXISTS podium_calls_phone ON public.podium_calls (phone, at DESC);
CREATE INDEX IF NOT EXISTS podium_calls_missed ON public.podium_calls (at DESC) WHERE handled_at IS NULL AND event IN ('missed', 'abandoned', 'voicemail_left');
ALTER TABLE public.podium_calls ENABLE ROW LEVEL SECURITY;
CREATE TABLE IF NOT EXISTS public.podium_messages (uid text PRIMARY KEY, direction text NOT NULL, phone text, body text, at timestamptz NOT NULL DEFAULT now(), status text, failure text,
  contact_name text, conversation_uid text, sender_uid text, customer_ids bigint[] NOT NULL DEFAULT '{}', sent_by bigint, test_to text, attachments jsonb, raw jsonb);
CREATE INDEX IF NOT EXISTS podium_messages_phone ON public.podium_messages (phone, at DESC);
ALTER TABLE public.podium_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.podium_conn ADD COLUMN IF NOT EXISTS webhook_uid text, ADD COLUMN IF NOT EXISTS webhook_at timestamptz, ADD COLUMN IF NOT EXISTS hook_last jsonb;

CREATE OR REPLACE FUNCTION public._podium_digits(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $f$ SELECT nullif(right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10), '') $f$;
CREATE OR REPLACE FUNCTION public._podium_customers(p_phone text) RETURNS bigint[]
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce((SELECT array_agg(DISTINCT coalesce(c.merged_into_id, c.id)) FROM customer_contacts cc JOIN customers c ON c.id = cc.customer_id
    WHERE cc.kind IN ('phone', 'mobile') AND length(public._podium_digits(p_phone)) = 10 AND right(regexp_replace(cc.value, '\D', '', 'g'), 10) = public._podium_digits(p_phone)), '{}') $f$;
CREATE INDEX IF NOT EXISTS customer_contacts_last10 ON public.customer_contacts ((right(regexp_replace(value, '\D', '', 'g'), 10))) WHERE kind IN ('phone', 'mobile');

-- the secret Podium signs its messages with (made once, kept in the vault)
CREATE OR REPLACE FUNCTION public._podium_hook_secret() RETURNS text
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions' AS $f$
DECLARE v text;
BEGIN
  SELECT decrypted_secret INTO v FROM vault.decrypted_secrets WHERE name = 'podium_webhook_secret' LIMIT 1;
  IF v IS NULL THEN v := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''); PERFORM vault.create_secret(v, 'podium_webhook_secret', 'Podium connection'); END IF;
  RETURN v;
END $f$;
CREATE OR REPLACE FUNCTION public._podium_hook_set(p_uid text) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE podium_conn SET webhook_uid = p_uid, webhook_at = CASE WHEN p_uid IS NULL THEN NULL ELSE now() END WHERE id = 1 $f$;
CREATE OR REPLACE FUNCTION public._podium_hook_note(p jsonb) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE podium_conn SET hook_last = p || jsonb_build_object('at', now()) WHERE id = 1 $f$;

-- one call from Podium (from the live feed or from the catch-up list): keep it, and show the call pop-up for a call coming in
CREATE OR REPLACE FUNCTION public._podium_call_in(p_event text, p jsonb) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_uid text := nullif(p ->> 'uid', ''); v_ev text := lower(regexp_replace(coalesce(nullif(p_event, ''), p ->> 'eventType', 'completed'), '^call\.', ''));
  v_phone text := public._podium_digits(coalesce(p ->> 'customerPhoneNumber', p #>> '{contact,phoneNumber}')); v_new boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;
  INSERT INTO podium_calls (uid, event, direction, phone, location_phone, started_at, ended_at, duration_s, has_voicemail, voicemail, details_url, customer_ids, user_uid, raw, at)
  VALUES (v_uid, v_ev, lower(p ->> 'direction'), v_phone, public._podium_digits(p ->> 'locationPhoneNumber'), (p ->> 'startedAt')::timestamptz, (p ->> 'endedAt')::timestamptz,
    nullif(p ->> 'durationSeconds', '')::numeric::int, coalesce((p ->> 'hasVoicemail')::boolean, false), nullif(p -> 'voicemail', 'null'::jsonb), p ->> 'phoneDetailsUrl',
    public._podium_customers(v_phone), p ->> 'userUid', p, coalesce((p ->> 'startedAt')::timestamptz, (p ->> 'createdAt')::timestamptz, now()))
  ON CONFLICT (uid) DO UPDATE SET event = CASE WHEN EXCLUDED.event = 'received' AND podium_calls.event <> 'received' THEN podium_calls.event ELSE EXCLUDED.event END,
    direction = coalesce(EXCLUDED.direction, podium_calls.direction), ended_at = coalesce(EXCLUDED.ended_at, podium_calls.ended_at), started_at = coalesce(EXCLUDED.started_at, podium_calls.started_at),
    duration_s = coalesce(EXCLUDED.duration_s, podium_calls.duration_s), has_voicemail = EXCLUDED.has_voicemail OR podium_calls.has_voicemail, voicemail = coalesce(EXCLUDED.voicemail, podium_calls.voicemail),
    details_url = coalesce(EXCLUDED.details_url, podium_calls.details_url), user_uid = coalesce(EXCLUDED.user_uid, podium_calls.user_uid), raw = EXCLUDED.raw, customer_ids = EXCLUDED.customer_ids
  RETURNING (xmax = 0) INTO v_new;
  IF v_new AND v_ev = 'received' AND coalesce(lower(p ->> 'direction'), 'inbound') = 'inbound' THEN   -- the pop-up "who is calling"
    PERFORM public.podium_call_in('call.received', v_phone, nullif(p #>> '{contact,name}', ''), v_uid, jsonb_build_object('from', 'podium-hook'));
  END IF;
END $f$;

CREATE OR REPLACE FUNCTION public._podium_calls_in(p jsonb) RETURNS int
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE c jsonb; n int := 0;
BEGIN
  FOR c IN SELECT * FROM jsonb_array_elements(coalesce(p, '[]'::jsonb)) LOOP PERFORM public._podium_call_in(NULL, c); n := n + 1; END LOOP;
  RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public._podium_calls_in(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._podium_calls_in(jsonb) TO service_role;

-- one text from Podium, or one the app just sent
CREATE OR REPLACE FUNCTION public._podium_msg_in(p_dir text, p_status text, p jsonb, p_sent_by bigint DEFAULT NULL, p_test_to text DEFAULT NULL) RETURNS text
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_uid text := nullif(p ->> 'uid', ''); v_phone text := public._podium_digits(coalesce(p #>> '{conversation,channel,identifier}', p #>> '{channel,identifier}', p ->> 'phone'));
  v_body text := coalesce(p ->> 'body', p #>> '{items,0,body}', ''); v_at timestamptz := coalesce((p ->> 'createdAt')::timestamptz, now()); v_old text;
BEGIN
  IF v_uid IS NULL THEN v_uid := 'app-' || replace(gen_random_uuid()::text, '-', ''); END IF;
  IF p_dir = 'out' AND v_uid NOT LIKE 'app-%' THEN   -- Podium telling us about a text the app itself sent a moment ago: same row, not a second one
    SELECT uid INTO v_old FROM podium_messages WHERE uid LIKE 'app-%' AND direction = 'out' AND coalesce(test_to, phone) = v_phone AND body = v_body AND at > v_at - interval '10 minutes' ORDER BY at DESC LIMIT 1;
    IF v_old IS NOT NULL THEN UPDATE podium_messages SET uid = v_uid, status = coalesce(p_status, status), failure = p ->> 'failureReason', raw = p WHERE uid = v_old; RETURN v_uid; END IF;
  END IF;
  INSERT INTO podium_messages (uid, direction, phone, body, at, status, failure, contact_name, conversation_uid, sender_uid, customer_ids, sent_by, test_to, attachments, raw)
  VALUES (v_uid, p_dir, v_phone, v_body, v_at, p_status, p ->> 'failureReason', nullif(coalesce(p ->> 'contactName', p #>> '{contact,name}'), ''), p #>> '{conversation,uid}',
    coalesce(p ->> 'senderUid', p #>> '{sender,uid}'), public._podium_customers(v_phone), p_sent_by, p_test_to,
    (SELECT jsonb_agg(jsonb_build_object('url', i ->> 'attachmentUrl', 'type', i ->> 'attachmentContentType')) FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p -> 'items') = 'array' THEN p -> 'items' ELSE '[]'::jsonb END) i WHERE i ->> 'attachmentUrl' IS NOT NULL), p)
  ON CONFLICT (uid) DO UPDATE SET status = coalesce(EXCLUDED.status, podium_messages.status), failure = coalesce(EXCLUDED.failure, podium_messages.failure), raw = EXCLUDED.raw;
  RETURN v_uid;
END $f$;

-- who may text customers from the app, and what the edge function needs to know to send one
CREATE OR REPLACE FUNCTION public.podium_text_who() RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._rec_ok() THEN jsonb_build_object('user', public.current_app_user_id(),
    'name', (SELECT nullif(btrim(e.first_name), '') FROM app_users u JOIN employees e ON e.id = u.employee_id WHERE u.id = public.current_app_user_id()),
    'test_to', (SELECT CASE WHEN nullif(btrim(send_test_to), '') IS NOT NULL THEN coalesce(public._podium_digits(send_test_phone), public._podium_digits(public._app_user_phone(public.current_app_user_id())), 'none') END FROM company_settings LIMIT 1)) END $f$;
-- may this number get a text for this customer? (it must be one of the customer's own numbers, and not marked "no texts")
CREATE OR REPLACE FUNCTION public._podium_text_check(p_customer bigint, p_phone text) RETURNS text
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM customer_contacts cc WHERE cc.customer_id = p_customer AND cc.kind IN ('phone', 'mobile') AND public._podium_digits(cc.value) = public._podium_digits(p_phone)) THEN 'not_theirs'
    WHEN EXISTS (SELECT 1 FROM customer_contacts cc WHERE cc.kind IN ('phone', 'mobile') AND public._podium_digits(cc.value) = public._podium_digits(p_phone) AND cc.allow_sms IS FALSE) THEN 'no_texts' ELSE 'ok' END $f$;

-- the customer page: this customer's numbers, and their texts and calls from Podium, newest first
CREATE OR REPLACE FUNCTION public.podium_thread(p_customer bigint, p_limit int DEFAULT 200) RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  WITH ph AS (SELECT DISTINCT ON (public._podium_digits(cc.value)) public._podium_digits(cc.value) AS d, cc.value, cc.kind, cc.contact_name, cc.is_primary, cc.allow_sms
      FROM customer_contacts cc WHERE cc.customer_id = p_customer AND cc.kind IN ('phone', 'mobile') AND length(public._podium_digits(cc.value)) = 10
      ORDER BY public._podium_digits(cc.value), (cc.kind = 'mobile') DESC, cc.is_primary DESC NULLS LAST),
  it AS (SELECT m.at, jsonb_build_object('k', 'text', 'uid', m.uid, 'dir', m.direction, 'phone', m.phone, 'body', m.body, 'at', m.at, 'status', m.status, 'failure', m.failure, 'test_to', m.test_to,
        'by', (SELECT nullif(btrim(e.first_name), '') FROM app_users u JOIN employees e ON e.id = u.employee_id WHERE u.id = m.sent_by), 'files', m.attachments) j
      FROM podium_messages m WHERE m.phone IN (SELECT d FROM ph)
    UNION ALL SELECT c.at, jsonb_build_object('k', 'call', 'uid', c.uid, 'dir', c.direction, 'phone', c.phone, 'event', c.event, 'at', c.at, 'secs', c.duration_s, 'voicemail', c.has_voicemail, 'url', c.details_url)
      FROM podium_calls c WHERE c.phone IN (SELECT d FROM ph) AND c.event <> 'received')
  SELECT CASE WHEN NOT public._rec_ok() THEN NULL ELSE jsonb_build_object(
    'live', (SELECT webhook_uid IS NOT NULL FROM podium_conn WHERE id = 1), 'connected', EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'podium_refresh_token'),
    'test_to', (public.podium_text_who() ->> 'test_to'),
    'phones', coalesce((SELECT jsonb_agg(jsonb_build_object('d', d, 'value', value, 'kind', kind, 'name', contact_name, 'main', is_primary, 'no_texts', allow_sms IS FALSE) ORDER BY (kind = 'mobile') DESC, is_primary DESC NULLS LAST) FROM ph), '[]'::jsonb),
    'items', coalesce((SELECT jsonb_agg(j ORDER BY at DESC) FROM (SELECT * FROM it ORDER BY at DESC LIMIT greatest(1, least(coalesce(p_limit, 200), 1000))) x), '[]'::jsonb)) END $f$;

-- Tasks page: calls we missed that nobody has dealt with yet (last 14 days; a later call with that number that was completed clears it by itself)
CREATE OR REPLACE FUNCTION public.podium_missed_list() RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._rec_ok() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('uid', c.uid, 'at', c.at, 'phone', c.phone, 'event', c.event, 'voicemail', c.has_voicemail, 'url', c.details_url,
      'times', (SELECT count(*) FROM podium_calls x WHERE x.phone = c.phone AND x.handled_at IS NULL AND x.event IN ('missed', 'abandoned', 'voicemail_left') AND x.at > now() - interval '14 days'),
      'customers', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', cu.id, 'name', cu.display_name)), '[]'::jsonb) FROM customers cu WHERE cu.id = ANY (c.customer_ids))) ORDER BY c.at DESC)
    FROM (SELECT DISTINCT ON (phone) * FROM podium_calls WHERE handled_at IS NULL AND event IN ('missed', 'abandoned', 'voicemail_left') AND coalesce(direction, 'inbound') = 'inbound' AND at > now() - interval '14 days' AND phone IS NOT NULL
      ORDER BY phone, at DESC) c
    WHERE NOT EXISTS (SELECT 1 FROM podium_calls d WHERE d.phone = c.phone AND d.event = 'completed' AND d.at > c.at)), '[]'::jsonb) END $f$;
CREATE OR REPLACE FUNCTION public.podium_missed_done(p_phone text, p_undo boolean DEFAULT false) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int;
BEGIN
  IF NOT public._rec_ok() THEN RAISE EXCEPTION 'Only office people and owners can do this'; END IF;
  IF p_undo THEN UPDATE podium_calls SET handled_at = NULL, handled_by = NULL WHERE phone = public._podium_digits(p_phone) AND handled_at > now() - interval '1 day' AND handled_by = public.current_app_user_id();
  ELSE UPDATE podium_calls SET handled_at = now(), handled_by = public.current_app_user_id() WHERE phone = public._podium_digits(p_phone) AND handled_at IS NULL AND event IN ('missed', 'abandoned', 'voicemail_left'); END IF;
  GET DIAGNOSTICS n = ROW_COUNT; RETURN jsonb_build_object('n', n);
END $f$;

-- Settings → Podium: is the live feed on, and when did Podium last tell us something
CREATE OR REPLACE FUNCTION public.podium_live_state() RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE (SELECT jsonb_build_object('on', webhook_uid IS NOT NULL, 'since', webhook_at, 'last', hook_last,
    'calls', (SELECT count(*) FROM podium_calls), 'texts', (SELECT count(*) FROM podium_messages), 'last_call', (SELECT max(at) FROM podium_calls), 'last_text', (SELECT max(at) FROM podium_messages)) FROM podium_conn WHERE id = 1) END $f$;

REVOKE EXECUTE ON FUNCTION public._podium_customers(text), public._podium_hook_secret(), public._podium_hook_set(text), public._podium_hook_note(jsonb), public._podium_call_in(text, jsonb),
  public._podium_msg_in(text, text, jsonb, bigint, text), public.podium_text_who(), public._podium_text_check(bigint, text), public.podium_thread(bigint, int), public.podium_missed_list(),
  public.podium_missed_done(text, boolean), public.podium_live_state() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.podium_text_who(), public.podium_thread(bigint, int), public.podium_missed_list(), public.podium_missed_done(text, boolean), public.podium_live_state() TO authenticated;
GRANT EXECUTE ON FUNCTION public._podium_customers(text), public._podium_hook_secret(), public._podium_hook_set(text), public._podium_hook_note(jsonb), public._podium_call_in(text, jsonb),
  public._podium_msg_in(text, text, jsonb, bigint, text), public._podium_text_check(bigint, text) TO service_role;
-- the Edge Functions read podium_conn themselves (which location to send from, the webhook's id): without this the first text failed with "Podium did not tell me which location to send from" (Nov 10)
GRANT SELECT ON public.podium_conn TO service_role;
NOTIFY pgrst, 'reload schema';

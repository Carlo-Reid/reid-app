-- AcceptPay connection (Carlo, Nov 18, 2026): the app signs in to AcceptPay's API by itself and brings in the EFT / PAP
-- transaction results, in place of waiting for the emailed report file. READ ONLY: nothing is ever created, changed,
-- voided or stopped at AcceptPay from here.
--   * The API username and key are typed once by an owner on the Security page (PAP payments -> Settings). They are kept
--     in the locked vault and are never sent back to the browser, never written in the code, a chat or the Sync folder.
--   * The Edge Function `acceptpay` (supabase/functions/acceptpay) does the talking: Test it, and Get the newest payments.
--   * What comes in lands in pap_inbox as one more "file" with the same ten columns as the emailed report
--     (Transaction ID, Process Date, Return Date, Type, First Name, Last Name, Response, Amount, Settled, Reference),
--     so Settlement files, Check it, Post, NSF and chargebacks all work as they do for an emailed file.
--     Nothing is posted by itself: an owner still presses Post.
--   * A transaction is brought in once for each answer the bank gives (acceptpay_txn). No bank account details are asked for or kept.

CREATE TABLE IF NOT EXISTS public.acceptpay_conn (id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  env text, user_hint text, keys_at timestamptz, keys_by bigint,
  tested_at timestamptz, test_ok boolean, test_note text, account jsonb,
  last_fetch timestamptz, last_since date, last_note text, last_error text, last_error_at timestamptz,
  probe jsonb, auto boolean NOT NULL DEFAULT true, auto_at timestamptz);
INSERT INTO public.acceptpay_conn (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.acceptpay_conn ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.acceptpay_conn FROM PUBLIC, anon, authenticated;

-- one line for each AcceptPay transaction already brought in, with the bank's answer it had then
CREATE TABLE IF NOT EXISTS public.acceptpay_txn (id bigint PRIMARY KEY, response text, status text, inbox_id bigint, times int NOT NULL DEFAULT 1,
  first_at timestamptz NOT NULL DEFAULT now(), at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.acceptpay_txn ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.acceptpay_txn FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._acceptpay_secret_set(p_name text, p_value text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'vault' AS $f$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM vault.secrets WHERE name = p_name;
  IF coalesce(p_value, '') = '' THEN IF v_id IS NOT NULL THEN DELETE FROM vault.secrets WHERE id = v_id; END IF;
  ELSIF v_id IS NULL THEN PERFORM vault.create_secret(p_value, p_name, 'AcceptPay connection');
  ELSE PERFORM vault.update_secret(v_id, p_value); END IF;
END $f$;

-- who may use the connection: owners (by role, rule number one)
CREATE OR REPLACE FUNCTION public.acceptpay_allowed() RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN coalesce(public._is_owner(), false) THEN public.current_app_user_id() END $f$;

-- what the Security page shows. The username and key are never in it.
CREATE OR REPLACE FUNCTION public.acceptpay_state() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'vault' AS $f$
  SELECT CASE WHEN NOT coalesce(public._sec_ok(), false) THEN NULL ELSE
    jsonb_build_object('owner', coalesce(public._is_owner(), false),
      'has_keys', (SELECT count(*) = 2 FROM vault.secrets WHERE name IN ('acceptpay_username', 'acceptpay_api_key')),
      'last_fetch', c.last_fetch, 'last_since', c.last_since, 'last_note', c.last_note, 'auto', c.auto, 'test_ok', c.test_ok)
    || CASE WHEN coalesce(public._is_owner(), false) THEN jsonb_build_object('env', c.env, 'user_hint', c.user_hint, 'keys_at', c.keys_at,
         'tested_at', c.tested_at, 'test_note', c.test_note, 'account', c.account, 'last_error', c.last_error, 'last_error_at', c.last_error_at,
         'auto_at', c.auto_at, 'brought_in', (SELECT count(*) FROM acceptpay_txn)) ELSE '{}'::jsonb END END
  FROM acceptpay_conn c WHERE c.id = 1 $f$;

-- an owner types the username and the key once. Both empty = take the connection off.
CREATE OR REPLACE FUNCTION public.acceptpay_set_keys(p_user text, p_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'vault' AS $f$
DECLARE u text := btrim(coalesce(p_user, '')); k text := btrim(coalesce(p_key, ''));
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  IF u = '' AND k = '' THEN
    PERFORM public._acceptpay_secret_set('acceptpay_username', ''); PERFORM public._acceptpay_secret_set('acceptpay_api_key', '');
    UPDATE acceptpay_conn SET env = NULL, user_hint = NULL, keys_at = NULL, keys_by = NULL, tested_at = NULL, test_ok = NULL, test_note = NULL,
      account = NULL, last_error = NULL, last_error_at = NULL WHERE id = 1;
    RETURN jsonb_build_object('ok', true, 'off', true);
  END IF;
  IF u = '' OR k = '' THEN RAISE EXCEPTION 'Type both the username and the key'; END IF;
  IF length(u) > 200 OR length(k) > 500 OR u ~ '\s' OR k ~ '\s' THEN RAISE EXCEPTION 'That does not look like a username and a key (no spaces)'; END IF;
  PERFORM public._acceptpay_secret_set('acceptpay_username', u); PERFORM public._acceptpay_secret_set('acceptpay_api_key', k);
  UPDATE acceptpay_conn SET user_hint = left(u, 2) || repeat('•', greatest(length(u) - 2, 3)), keys_at = now(), keys_by = public.current_app_user_id(),
    env = NULL, tested_at = NULL, test_ok = NULL, test_note = NULL, account = NULL, last_error = NULL, last_error_at = NULL WHERE id = 1;
  RETURN jsonb_build_object('ok', true);
END $f$;

-- the check by itself, twice a day: on or off
CREATE OR REPLACE FUNCTION public.acceptpay_set_auto(p_on boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  UPDATE acceptpay_conn SET auto = coalesce(p_on, false) WHERE id = 1;
  RETURN jsonb_build_object('ok', true, 'auto', coalesce(p_on, false));
END $f$;

-- ---- for the Edge Function only (service role) ----
CREATE OR REPLACE FUNCTION public._acceptpay_cron_key() RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'vault', 'extensions' AS $f$
DECLARE v text;
BEGIN
  SELECT decrypted_secret INTO v FROM vault.decrypted_secrets WHERE name = 'acceptpay_cron_key' LIMIT 1;
  IF coalesce(v, '') = '' THEN v := encode(gen_random_bytes(32), 'hex'); PERFORM public._acceptpay_secret_set('acceptpay_cron_key', v); END IF;
  RETURN v;
END $f$;

CREATE OR REPLACE FUNCTION public._acceptpay_secrets() RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public', 'vault' AS $f$
  SELECT coalesce(jsonb_object_agg(replace(name, 'acceptpay_', ''), decrypted_secret), '{}'::jsonb)
         || (SELECT jsonb_build_object('env', env, 'auto', auto, 'last_since', last_since, 'last_fetch', last_fetch) FROM acceptpay_conn WHERE id = 1)
  FROM vault.decrypted_secrets WHERE name IN ('acceptpay_username', 'acceptpay_api_key', 'acceptpay_cron_key') $f$;

-- what a test or a fetch found out (never customer data: only yes / no, counts, field names)
CREATE OR REPLACE FUNCTION public._acceptpay_note(p jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE acceptpay_conn SET
    env = CASE WHEN p ? 'env' THEN nullif(p ->> 'env', '') ELSE env END,
    tested_at = CASE WHEN p ? 'test_ok' THEN now() ELSE tested_at END,
    test_ok = CASE WHEN p ? 'test_ok' THEN (p ->> 'test_ok')::boolean ELSE test_ok END,
    test_note = CASE WHEN p ? 'test_note' THEN left(p ->> 'test_note', 500) ELSE test_note END,
    account = CASE WHEN p ? 'account' THEN p -> 'account' ELSE account END,
    probe = CASE WHEN p ? 'probe' THEN p -> 'probe' ELSE probe END,
    last_error = CASE WHEN p ? 'error' THEN left(nullif(p ->> 'error', ''), 500) ELSE last_error END,
    last_error_at = CASE WHEN p ? 'error' THEN CASE WHEN nullif(p ->> 'error', '') IS NULL THEN NULL ELSE now() END ELSE last_error_at END,
    auto_at = CASE WHEN p ? 'auto_ran' THEN now() ELSE auto_at END
  WHERE id = 1 $f$;

-- of the updates AcceptPay lists [{Id, Response, Status}], the ones not brought in yet with that answer
CREATE OR REPLACE FUNCTION public._acceptpay_new(p jsonb) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(jsonb_agg(DISTINCT (x ->> 'Id')::bigint), '[]'::jsonb)
  FROM jsonb_array_elements(coalesce(p, '[]'::jsonb)) x
  WHERE (x ->> 'Id') ~ '^\d{1,18}$'
    AND NOT EXISTS (SELECT 1 FROM acceptpay_txn t WHERE t.id = (x ->> 'Id')::bigint AND t.response IS NOT DISTINCT FROM nullif(btrim(coalesce(x ->> 'Response', '')), '')) $f$;

-- the rows the function read: [{id, response, status, row: [ten words, in the emailed file's own order]}]
-- They go on today's AcceptPay "file" while it is still waiting and not posted, else on a new one.
CREATE OR REPLACE FUNCTION public._acceptpay_file_in(p_rows jsonb, p_since date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_day date := (now() AT TIME ZONE 'America/Toronto')::date; v_id bigint; v_n int := 0; v_k int := 0; r jsonb; v_row jsonb; v_txn text; v_old acceptpay_txn;
  v_tbl jsonb := '[]'::jsonb; v_rows jsonb := '[]'::jsonb; v_done jsonb := '[]'::jsonb; v_mid text;
  c_cols CONSTANT jsonb := '["Transaction ID","Process Date","Return Date","Type","First Name","Last Name","Response","Amount","Settled","Reference"]';
BEGIN
  FOR r IN SELECT x FROM jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x LOOP
    CONTINUE WHEN (r ->> 'id') !~ '^\d{1,18}$' OR jsonb_typeof(r -> 'row') <> 'array' OR jsonb_array_length(r -> 'row') <> 10;
    SELECT * INTO v_old FROM acceptpay_txn WHERE id = (r ->> 'id')::bigint;
    CONTINUE WHEN v_old.id IS NOT NULL AND v_old.response IS NOT DISTINCT FROM nullif(r ->> 'response', '');
    CONTINUE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(v_done) d WHERE d ->> 'id' = r ->> 'id');   -- the same transaction twice in one go: the next look takes the second
    v_row := r -> 'row';
    -- the same transaction with a NEW answer from the bank (approved first, came back later): it gets its own number
    -- ("40719409-901") so the settlement post, which never posts a Transaction ID twice, still reads the new answer
    IF v_old.id IS NOT NULL THEN v_txn := (r ->> 'id') || '-' || coalesce(nullif(regexp_replace(coalesce(r ->> 'response', ''), '[^A-Za-z0-9]', '', 'g'), ''), 'x' || (v_old.times + 1));
      v_row := jsonb_set(v_row, '{0}', to_jsonb(v_txn)); END IF;
    v_tbl := v_tbl || jsonb_build_array(v_row);
    v_rows := v_rows || jsonb_build_array(jsonb_build_array(v_row ->> 9, btrim(concat_ws(' ', nullif(v_row ->> 4, ''), nullif(v_row ->> 5, ''))), '', v_row ->> 7, v_row ->> 6));
    v_done := v_done || jsonb_build_array(jsonb_build_object('id', r ->> 'id', 'response', r ->> 'response', 'status', r ->> 'status'));
    v_n := v_n + 1;
  END LOOP;
  IF v_n > 0 THEN
    SELECT i.id INTO v_id FROM pap_inbox i WHERE i.message_id LIKE 'acceptpay-api-' || v_day::text || '%' AND i.status = 'waiting'
       AND NOT EXISTS (SELECT 1 FROM pap_settle s WHERE s.inbox_id = i.id) ORDER BY i.id DESC LIMIT 1;
    IF v_id IS NULL THEN
      SELECT count(*) INTO v_k FROM pap_inbox WHERE message_id LIKE 'acceptpay-api-' || v_day::text || '%';
      v_mid := 'acceptpay-api-' || v_day::text || CASE WHEN v_k > 0 THEN '-' || (v_k + 1) ELSE '' END;
      INSERT INTO pap_inbox (message_id, received_at, from_addr, from_name, subject, file_name, pap_list, head, rows, cols, tbl, status)
      VALUES (v_mid, now(), NULL, 'AcceptPay (connection)', 'Brought in from AcceptPay by the connection',
        'From AcceptPay ' || to_char(v_day, 'Mon FMDD, YYYY') || CASE WHEN v_k > 0 THEN ' (' || (v_k + 1) || ')' ELSE '' END, 'monthly',
        '["Reference","First Name + Last Name",null,"Amount","Response"]'::jsonb, v_rows, c_cols, v_tbl, 'waiting') RETURNING id INTO v_id;
    ELSE
      UPDATE pap_inbox SET tbl = coalesce(tbl, '[]'::jsonb) || v_tbl, rows = coalesce(rows, '[]'::jsonb) || v_rows WHERE id = v_id;
    END IF;
    INSERT INTO acceptpay_txn (id, response, status, inbox_id)
    SELECT DISTINCT ON ((x ->> 'id')::bigint) (x ->> 'id')::bigint, nullif(x ->> 'response', ''), nullif(x ->> 'status', ''), v_id
    FROM jsonb_array_elements(v_done) WITH ORDINALITY d(x, o) ORDER BY (x ->> 'id')::bigint, o DESC
    ON CONFLICT (id) DO UPDATE SET response = EXCLUDED.response, status = EXCLUDED.status, inbox_id = EXCLUDED.inbox_id, times = acceptpay_txn.times + 1, at = now();
  END IF;
  RETURN jsonb_build_object('added', v_n, 'inbox_id', v_id);
END $f$;

-- a fetch finished: remember how far it looked
CREATE OR REPLACE FUNCTION public._acceptpay_done(p_since date, p_note text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE acceptpay_conn SET last_fetch = now(), last_since = p_since, last_note = left(p_note, 500), last_error = NULL, last_error_at = NULL WHERE id = 1 $f$;

-- the check by itself: the database asks the Edge Function to look (only when the keys are in and it is turned on)
CREATE OR REPLACE FUNCTION public._acceptpay_dispatch() RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'vault' AS $f$
DECLARE v_req bigint;
BEGIN
  IF NOT (SELECT auto FROM acceptpay_conn WHERE id = 1) OR (SELECT count(*) FROM vault.secrets WHERE name IN ('acceptpay_username', 'acceptpay_api_key')) < 2 THEN RETURN NULL; END IF;
  SELECT net.http_post(url := 'https://hplvhfkvwcwackyauirw.supabase.co/functions/v1/acceptpay',
    body := '{"action":"fetch","auto":true}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-key', public._acceptpay_cron_key()),
    timeout_milliseconds := 140000) INTO v_req;
  RETURN v_req;
END $f$;

REVOKE EXECUTE ON FUNCTION public._acceptpay_secret_set(text, text), public._acceptpay_cron_key(), public._acceptpay_secrets(), public._acceptpay_note(jsonb),
  public._acceptpay_new(jsonb), public._acceptpay_file_in(jsonb, date), public._acceptpay_done(date, text), public._acceptpay_dispatch(),
  public.acceptpay_allowed(), public.acceptpay_state(), public.acceptpay_set_keys(text, text), public.acceptpay_set_auto(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.acceptpay_allowed(), public.acceptpay_state(), public.acceptpay_set_keys(text, text), public.acceptpay_set_auto(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public._acceptpay_secrets(), public._acceptpay_note(jsonb), public._acceptpay_new(jsonb), public._acceptpay_file_in(jsonb, date),
  public._acceptpay_done(date, text) TO service_role;

-- twice a day (6:23 a.m. and 4:23 p.m. Ottawa winter time; an hour later in summer)
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'acceptpay-check';
SELECT cron.schedule('acceptpay-check', '23 11,21 * * *', $$SELECT public._acceptpay_dispatch()$$);

NOTIFY pgrst, 'reload schema';

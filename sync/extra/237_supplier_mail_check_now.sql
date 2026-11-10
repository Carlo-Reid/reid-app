-- Auto update: "Check again now" in Eco Man's bubble, and a real every-10-minutes check of the supplier mailbox.
-- GitHub was only starting the "every 10 minutes" mailbox job every 4 to 7 hours (Carlo noticed Nov 9: it said
-- "last looked 6:09" at 8:13). So the database starts the job itself: every 10 minutes (pg_cron), and when someone
-- presses the button. Starting it needs a GitHub key, kept in the database's locked vault (name github_actions_token).
-- An owner pastes it in the app once (supplier_mail_set_key); it is never sent back to the app. Safe to run more than once.
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

-- start the mailbox job on GitHub; NULL when there is no key yet
CREATE OR REPLACE FUNCTION public._supplier_mail_dispatch() RETURNS bigint
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_key text; v_req bigint;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'github_actions_token' LIMIT 1;
  IF coalesce(v_key, '') = '' THEN RETURN NULL; END IF;
  SELECT net.http_post(
    url := 'https://api.github.com/repos/Carlo-Reid/reid-app/actions/workflows/supplier-mail.yml/dispatches',
    body := '{"ref":"main"}'::jsonb,
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key, 'Accept', 'application/vnd.github+json',
                                  'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'reid-app', 'Content-Type', 'application/json'),
    timeout_milliseconds := 8000) INTO v_req;
  INSERT INTO supplier_mail_state (key, value) VALUES ('last_dispatch', now()::text)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  RETURN v_req;
END $function$;

-- the button: {need_key} / {wait} / {ok, req}
CREATE OR REPLACE FUNCTION public.supplier_mail_check_now() RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_last timestamptz; v_req bigint;
BEGIN
  IF NOT public._can_approve_costs() THEN RAISE EXCEPTION 'You need to be able to approve costs for this'; END IF;
  SELECT value::timestamptz INTO v_last FROM supplier_mail_state WHERE key = 'last_dispatch';
  IF v_last IS NOT NULL AND v_last > now() - interval '90 seconds' THEN RETURN jsonb_build_object('wait', true); END IF;
  v_req := public._supplier_mail_dispatch();
  IF v_req IS NULL THEN RETURN jsonb_build_object('need_key', true, 'owner', public._is_owner()); END IF;
  RETURN jsonb_build_object('ok', true, 'req', v_req);
END $function$;

-- did GitHub take it? 204 = yes. NULL = no answer yet.
CREATE OR REPLACE FUNCTION public.supplier_mail_check_result(p_req bigint) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_code int; v_err text;
BEGIN
  IF NOT public._can_approve_costs() THEN RETURN '{}'::jsonb; END IF;
  SELECT status_code, error_msg INTO v_code, v_err FROM net._http_response WHERE id = p_req;
  RETURN jsonb_build_object('code', v_code, 'error', v_err);
END $function$;

-- an owner saves (or replaces) the GitHub key; '' takes it out
CREATE OR REPLACE FUNCTION public.supplier_mail_set_key(p_key text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_id uuid; v_key text := btrim(coalesce(p_key, ''));
BEGIN
  IF NOT public._is_owner() THEN RAISE EXCEPTION 'Only an owner can do this'; END IF;
  IF v_key <> '' AND v_key !~ '^(github_pat_|ghp_)[A-Za-z0-9_]{20,}$' THEN RAISE EXCEPTION 'That does not look like a GitHub key. It starts with github_pat_'; END IF;
  SELECT id INTO v_id FROM vault.secrets WHERE name = 'github_actions_token';
  IF v_key = '' THEN IF v_id IS NOT NULL THEN DELETE FROM vault.secrets WHERE id = v_id; END IF; RETURN jsonb_build_object('saved', false); END IF;
  IF v_id IS NULL THEN PERFORM vault.create_secret(v_key, 'github_actions_token', 'Starts the supplier mailbox check on GitHub');
  ELSE PERFORM vault.update_secret(v_id, v_key); END IF;
  RETURN jsonb_build_object('saved', true);
END $function$;

REVOKE EXECUTE ON FUNCTION public._supplier_mail_dispatch(), public.supplier_mail_check_now(), public.supplier_mail_check_result(bigint), public.supplier_mail_set_key(text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public._supplier_mail_dispatch() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.supplier_mail_check_now(), public.supplier_mail_check_result(bigint), public.supplier_mail_set_key(text) TO authenticated;

-- every 10 minutes, for real (does nothing until the key is saved)
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'supplier-mail-10min';
SELECT cron.schedule('supplier-mail-10min', '*/10 * * * *', $$SELECT public._supplier_mail_dispatch()$$);
NOTIFY pgrst, 'reload schema';

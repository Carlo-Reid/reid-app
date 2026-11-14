-- Payroll: the app watches the CRA's T4127 page (Payroll Deductions Formulas) once a day and says when a new edition is out
-- (George, Nov 14: "Build the watcher into the app itself"). It only tells: the numbers are never filled in by themselves.
-- How: pg_cron runs _tax_watch_run() every day. It reads the answer to yesterday's fetch (pg_net keeps answers in net._http_response),
-- picks out every "123rd Edition ... Effective July 1, 2026" on the page, then asks for the page again.
-- The first time, every edition on the page is taken as already known (no alarm). After that, a new edition is kept as "new"
-- until an owner presses "Done, I put them in" (payroll_tax_watch_ack). Safe to run more than once.
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

ALTER TABLE company_settings ADD COLUMN IF NOT EXISTS payroll_tax_watch jsonb NOT NULL DEFAULT '{}'::jsonb;

-- read the page's answer, if one came back; returns the watch as it is after
CREATE OR REPLACE FUNCTION public._tax_watch_read() RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE w jsonb; v_req bigint; v_code int; v_err text; v_body text; m text[]; v_found jsonb := '[]'::jsonb;
        v_seen jsonb; v_new jsonb; e jsonb; v_first boolean;
BEGIN
  SELECT payroll_tax_watch INTO w FROM company_settings LIMIT 1; w := coalesce(w, '{}'::jsonb);
  v_req := nullif(w->>'req', '')::bigint;
  IF v_req IS NULL THEN RETURN w; END IF;
  SELECT status_code, error_msg, content INTO v_code, v_err, v_body FROM net._http_response WHERE id = v_req;
  IF NOT FOUND THEN
    -- no answer yet; after a day it is lost (pg_net keeps answers for a while only)
    IF (w->>'asked_at')::timestamptz < now() - interval '1 day' THEN
      w := w - 'req' || jsonb_build_object('status', 'no_answer');
      UPDATE company_settings SET payroll_tax_watch = w WHERE true;
    END IF;
    RETURN w;
  END IF;
  w := w - 'req';
  IF v_code IS DISTINCT FROM 200 OR v_body IS NULL THEN
    w := w || jsonb_build_object('status', 'error', 'err', coalesce(v_err, 'The CRA page answered ' || coalesce(v_code::text, 'nothing')), 'checked_at', now());
    UPDATE company_settings SET payroll_tax_watch = w WHERE true;
    RETURN w;
  END IF;
  -- the page's words only (no tags, no &nbsp;), so a link or a <span> between the words does not matter
  v_body := regexp_replace(regexp_replace(regexp_replace(v_body, '<[^>]*>', ' ', 'g'), '&nbsp;|&#160;|\u00a0', ' ', 'gi'), '\s+', ' ', 'g');
  FOR m IN SELECT regexp_matches(v_body, '(\d{2,4}) ?(?:st|nd|rd|th) ?Edition[^0-9]{0,60}Effective (January|July) 1,? (\d{4})', 'gi') LOOP
    e := jsonb_build_object('ed', m[1]::int, 'month', initcap(m[2]), 'year', m[3]::int);
    IF NOT v_found @> jsonb_build_array(e) THEN v_found := v_found || jsonb_build_array(e); END IF;
  END LOOP;
  IF jsonb_array_length(v_found) = 0 THEN
    -- the page changed its words: say so, so someone looks
    w := w || jsonb_build_object('status', 'unread', 'err', 'The CRA page came back, but no edition could be read on it. Look at it yourself.', 'checked_at', now());
    UPDATE company_settings SET payroll_tax_watch = w WHERE true;
    RETURN w;
  END IF;
  v_seen := coalesce(w->'seen', '[]'::jsonb); v_new := coalesce(w->'new', '[]'::jsonb);
  v_first := (w->'seen') IS NULL;
  FOR e IN SELECT * FROM jsonb_array_elements(v_found) LOOP
    IF NOT (v_seen @> jsonb_build_array(jsonb_build_object('ed', e->'ed'))) THEN
      v_seen := v_seen || jsonb_build_array(e);
      IF NOT v_first THEN v_new := v_new || jsonb_build_array(e || jsonb_build_object('found_at', now())); END IF;
    END IF;
  END LOOP;
  w := w || jsonb_build_object('status', 'ok', 'err', null, 'checked_at', now(), 'seen', v_seen, 'new', v_new, 'on_page', v_found);
  UPDATE company_settings SET payroll_tax_watch = w WHERE true;
  RETURN w;
END $f$;

-- read the last answer, then ask the CRA page again
CREATE OR REPLACE FUNCTION public._tax_watch_run() RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE w jsonb; v_req bigint;
BEGIN
  w := public._tax_watch_read();
  SELECT net.http_get(
    url := 'https://www.canada.ca/en/revenue-agency/services/forms-publications/payroll/t4127-payroll-deductions-formulas.html',
    headers := jsonb_build_object('User-Agent', 'reid-app payroll check (once a day)'),
    timeout_milliseconds := 20000) INTO v_req;
  w := w || jsonb_build_object('req', v_req, 'asked_at', now());
  UPDATE company_settings SET payroll_tax_watch = w WHERE true;
  RETURN w;
END $f$;

-- owners: what the watch knows now (reads a waiting answer first)
CREATE OR REPLACE FUNCTION public.payroll_tax_watch() RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE w jsonb;
BEGIN
  IF NOT public._src_owner() THEN RETURN '{}'::jsonb; END IF;
  w := public._tax_watch_read();
  RETURN w - 'req' || jsonb_build_object('waiting', (w->>'req') IS NOT NULL);
END $f$;

-- owners: look at the CRA page now (at most once every 2 minutes)
CREATE OR REPLACE FUNCTION public.payroll_tax_watch_now() RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE w jsonb;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  SELECT payroll_tax_watch INTO w FROM company_settings LIMIT 1;
  IF (w->>'asked_at')::timestamptz > now() - interval '2 minutes' THEN RETURN jsonb_build_object('wait', true); END IF;
  w := public._tax_watch_run();
  RETURN jsonb_build_object('ok', true);
END $f$;

-- owners: "Done, I put them in" for one new edition (it leaves the list; it stays in "seen")
CREATE OR REPLACE FUNCTION public.payroll_tax_watch_ack(p_ed int) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE w jsonb; v_new jsonb := '[]'::jsonb; e jsonb; v_done jsonb;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  SELECT payroll_tax_watch INTO w FROM company_settings LIMIT 1;
  FOR e IN SELECT * FROM jsonb_array_elements(coalesce(w->'new', '[]'::jsonb)) LOOP
    IF (e->>'ed')::int = p_ed THEN
      v_done := coalesce(w->'done', '[]'::jsonb) || jsonb_build_array(e || jsonb_build_object('done_by', public._staff_name(public.current_app_user_id()), 'done_at', now()));
      w := w || jsonb_build_object('done', v_done);
    ELSE v_new := v_new || jsonb_build_array(e); END IF;
  END LOOP;
  w := w || jsonb_build_object('new', v_new);
  UPDATE company_settings SET payroll_tax_watch = w WHERE true;
  RETURN w - 'req';
END $f$;

REVOKE EXECUTE ON FUNCTION public._tax_watch_read(), public._tax_watch_run(), public.payroll_tax_watch(), public.payroll_tax_watch_now(), public.payroll_tax_watch_ack(int) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public._tax_watch_read(), public._tax_watch_run() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.payroll_tax_watch(), public.payroll_tax_watch_now(), public.payroll_tax_watch_ack(int) TO authenticated;

-- once a day at 10:17 a.m. Ottawa (15:17 UTC in winter)
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'payroll-tax-watch';
SELECT cron.schedule('payroll-tax-watch', '17 15 * * *', $$SELECT public._tax_watch_run()$$);
-- first look right away, so the editions on the page now are known (no alarm for them)
DO $$ BEGIN IF (SELECT (payroll_tax_watch->'seen') IS NULL AND (payroll_tax_watch->>'req') IS NULL FROM company_settings LIMIT 1) THEN PERFORM public._tax_watch_run(); END IF; END $$;
NOTIFY pgrst, 'reload schema';

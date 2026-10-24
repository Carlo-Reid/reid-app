-- =====================================================================
-- Improvement 2: the email checkers really run every 10 minutes.
-- GitHub's own timer runs them every 3 to 5 hours when it's busy, so the database starts them instead:
-- every 10 minutes it asks GitHub to run "EFT mail" and "Supplier mail" (GitHub's timer stays on as a backup).
-- It needs a GitHub key, kept locked in the Supabase vault. Until the key is added nothing changes.
-- Add the key once in Supabase > SQL Editor:  select vault.create_secret('github_pat_…', 'github_dispatch_token');
-- Safe to run more than once.
-- =====================================================================
DO $$
BEGIN
  BEGIN CREATE EXTENSION IF NOT EXISTS pg_net; EXCEPTION WHEN others THEN RAISE NOTICE 'pg_net not added: %', SQLERRM; END;
  BEGIN CREATE EXTENSION IF NOT EXISTS pg_cron; EXCEPTION WHEN others THEN RAISE NOTICE 'pg_cron not added: %', SQLERRM; END;
END $$;

-- ask GitHub to run one workflow now (does nothing until the key is in the vault)
CREATE OR REPLACE FUNCTION public._gh_dispatch(p_workflow text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE tok text;
BEGIN
  IF p_workflow !~ '^[a-z0-9_-]+\.yml$' THEN RETURN NULL; END IF;
  IF to_regclass('vault.decrypted_secrets') IS NULL OR to_regnamespace('net') IS NULL THEN RETURN NULL; END IF;
  EXECUTE $q$SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'github_dispatch_token' ORDER BY created_at DESC LIMIT 1$q$ INTO tok;
  IF coalesce(btrim(tok), '') = '' THEN RETURN NULL; END IF;
  RETURN net.http_post(
    url := 'https://api.github.com/repos/Carlo-Reid/reid-app/actions/workflows/' || p_workflow || '/dispatches',
    body := jsonb_build_object('ref', 'main'),
    headers := jsonb_build_object('Authorization', 'Bearer ' || btrim(tok), 'Accept', 'application/vnd.github+json', 'User-Agent', 'reid-app-timer',
                                  'X-GitHub-Api-Version', '2022-11-28', 'Content-Type', 'application/json'),
    timeout_milliseconds := 5000);
END $$;
REVOKE EXECUTE ON FUNCTION public._gh_dispatch(text) FROM PUBLIC, anon, authenticated;

-- owners: is the timer on, and how did the last runs go
CREATE OR REPLACE FUNCTION public.schedule_status()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v jsonb := '{}'::jsonb; j jsonb; r jsonb; k boolean := false;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RETURN NULL; END IF;
  IF to_regclass('vault.decrypted_secrets') IS NOT NULL THEN
    EXECUTE $q$SELECT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'github_dispatch_token')$q$ INTO k;
  END IF;
  IF to_regclass('cron.job') IS NOT NULL THEN
    EXECUTE $q$SELECT coalesce(jsonb_agg(jsonb_build_object('name', jobname, 'when', schedule, 'on', active) ORDER BY jobname), '[]') FROM cron.job WHERE jobname LIKE 'reid-%'$q$ INTO j;
    EXECUTE $q$SELECT coalesce(jsonb_agg(x ORDER BY (x->>'at') DESC), '[]') FROM (
                 SELECT jsonb_build_object('name', j.jobname, 'at', d.start_time, 'status', d.status, 'msg', left(d.return_message, 200)) x
                 FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid WHERE j.jobname LIKE 'reid-%' ORDER BY d.start_time DESC LIMIT 10) y$q$ INTO r;
  END IF;
  RETURN jsonb_build_object('timer', to_regclass('cron.job') IS NOT NULL, 'web', to_regnamespace('net') IS NOT NULL, 'key', k, 'jobs', coalesce(j, '[]'), 'runs', coalesce(r, '[]'));
END $$;
REVOKE EXECUTE ON FUNCTION public.schedule_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.schedule_status() TO authenticated;

-- the timer: EFT mail on the 10s, Supplier mail 5 minutes later
DO $$
BEGIN
  IF to_regclass('cron.job') IS NOT NULL THEN
    PERFORM cron.schedule('reid-eft-mail', '*/10 * * * *', $c$SELECT public._gh_dispatch('eft-mail.yml')$c$);
    PERFORM cron.schedule('reid-supplier-mail', '5-59/10 * * * *', $c$SELECT public._gh_dispatch('supplier-mail.yml')$c$);
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

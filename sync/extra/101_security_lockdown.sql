-- =====================================================================
-- Improvement 1: lock down the database functions.
--  (a) Functions that run with full rights (SECURITY DEFINER) could be called by anyone who has the app's public key
--      (it's in the web page). Only marketing_unsubscribe and request_password_reset are meant to be public. All the
--      others are taken away from the public; signed-in staff (and the server) keep them.
--  (b) Owner / permission checks written as CASE WHEN NOT public._is_owner() ... (or _can_…() / current_staff_role() IN (…))
--      let a person with no role through, because "NOT unknown" isn't true. They're rewritten with coalesce(…, false).
-- Runs every sync, after the other pieces, so functions added later get the same treatment. Safe to run more than once.
-- =====================================================================
DO $$
DECLARE f record; keep text[] := ARRAY['marketing_unsubscribe', 'request_password_reset']; d text; d2 text;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.prosecdef AND p.proname <> ALL (keep) AND p.prokind = 'f'
             AND has_function_privilege('anon', p.oid, 'EXECUTE')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f.sig); END IF;
  END LOOP;
  FOR f IN SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.prosecdef AND p.prokind = 'f'
             AND p.prosrc ~* '(CASE WHEN|IF) NOT \(?public\.(_is_owner|_can_[a-z_]+|current_staff_role)\('
  LOOP
    d := pg_get_functiondef(f.oid);
    d2 := regexp_replace(d, '(CASE WHEN|IF) NOT (public\.(_is_owner|_can_[a-z_]+)\(\))', '\1 NOT coalesce(\2, false)', 'gi');
    d2 := regexp_replace(d2, '(CASE WHEN|IF) NOT \((public\.current_staff_role\(\) IN \([^)]*\))\)', '\1 NOT coalesce(\2, false)', 'gi');
    d2 := regexp_replace(d2, '(CASE WHEN|IF) NOT (public\.current_staff_role\(\) IN \([^)]*\))', '\1 NOT coalesce(\2, false)', 'gi');
    IF d2 <> d THEN EXECUTE d2; END IF;
  END LOOP;
END $$;
NOTIFY pgrst, 'reload schema';

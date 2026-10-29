-- The Security page as a permission an owner can turn on or off for each staff member (Staff page): "security.view".
-- The Security page's functions (pap_*) let in owners and anyone with it. Phyllis gets it.
INSERT INTO public.permissions (code, name, description, category, sort_order)
VALUES ('security.view', 'Security page', 'Open the Security page: PAP / EFT lists, the EFT mailbox, security customers', 'Pages', 90)
ON CONFLICT (code) DO NOTHING;

CREATE OR REPLACE FUNCTION public._sec_ok() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(public._is_owner(), false) OR public.has_permission('security.view') $$;
REVOKE EXECUTE ON FUNCTION public._sec_ok() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._sec_ok() TO authenticated;

-- every Security page function checks _sec_ok() instead of owners only (redone after each sync puts them back)
DO $$ DECLARE f record; src text; BEGIN
  FOR f IN SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname LIKE 'pap\_%' LOOP
    src := pg_get_functiondef(f.oid);
    IF src ~ '_is_owner\(\)' THEN
      src := regexp_replace(src, '(public\.)?_is_owner\(\)', 'public._sec_ok()', 'g');
      EXECUTE src;
    END IF;
  END LOOP;
END $$;

-- Phyllis (Philly): the Security page, if there's exactly one of her
DO $$ DECLARE v bigint[]; BEGIN
  SELECT array_agg(u.id) INTO v FROM app_users u LEFT JOIN employees e ON e.id = u.employee_id
   WHERE u.active AND (e.first_name ~* '^(philly|phyllis|phillis|phylis|phil?lis)' OR u.login_email ~* '^(philly|phyllis|phillis)');
  IF cardinality(v) = 1 THEN
    BEGIN INSERT INTO user_permissions (app_user_id, permission_code) VALUES (v[1], 'security.view') ON CONFLICT DO NOTHING;
    EXCEPTION WHEN others THEN RAISE NOTICE 'Could not give Phyllis the Security page: %', SQLERRM; END;
  ELSE RAISE NOTICE 'Phyllis: % matches, not given', coalesce(cardinality(v), 0); END IF;
END $$;
NOTIFY pgrst, 'reload schema';

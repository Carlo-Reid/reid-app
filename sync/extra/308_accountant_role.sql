-- The outside accountant (Carlo, Nov 16, 2026): a login like an employee's that only sees the Accounting page.
-- A new role, 'accountant'. It is in no other role list, so every role-gated function refuses it;
-- it is only added to the books (the Accounting page's own functions).
DO $$
DECLARE c record; d text;
BEGIN
  FOR c IN SELECT conname, pg_get_constraintdef(oid) AS def FROM pg_constraint
           WHERE conrelid = 'public.app_users'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%read_only%' AND pg_get_constraintdef(oid) NOT LIKE '%accountant%' LOOP
    EXECUTE format('ALTER TABLE public.app_users DROP CONSTRAINT %I', c.conname);
    ALTER TABLE public.app_users ADD CONSTRAINT app_users_role_check
      CHECK (role = ANY (ARRAY['owner','admin','office','dispatcher','accounting','warehouse','technician','sales','read_only','accountant']));
  END LOOP;
  -- the Staff page's save: let it take the new role
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'save_staff_member' LIMIT 1;
  IF d IS NOT NULL AND d NOT LIKE '%''accountant''%' AND d LIKE '%''sales'',''read_only'')%' THEN
    EXECUTE replace(d, '''sales'',''read_only'')', '''sales'',''read_only'',''accountant'')');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public._can_books() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.current_staff_role() IN ('owner', 'admin', 'accounting', 'accountant') OR public.has_permission('invoices.adjust')
$$;

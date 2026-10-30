-- est_new_version: keep the original's created_via (the column only takes its own set of values); version_of says it's a new version
DO $$ DECLARE s text; BEGIN
  SELECT pg_get_functiondef('public.est_new_version(bigint)'::regprocedure) INTO s;
  s := replace(s, 'coalesce(e.sold_by_employee_id, public._my_employee()), ''version'',', 'coalesce(e.sold_by_employee_id, public._my_employee()), e.created_via,');
  EXECUTE s;
END $$;
NOTIFY pgrst, 'reload schema';

-- Combine two staff records that are the same person (e.g. a ServiceTitan tech account and sales account).
-- employees.merged_into points the duplicate at the record to keep. After every sync, everything that points at the
-- duplicate (sales, installs, visits, commission, logins…) is moved to the kept record, so new ServiceTitan data lands
-- there too, and the duplicate is switched off. Safe to run more than once.
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS merged_into bigint REFERENCES public.employees(id);

CREATE OR REPLACE FUNCTION public._merge_employee(p_from bigint, p_to bigint)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
DECLARE c record; r record; n int := 0;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from = p_to THEN RETURN 0; END IF;
  -- every column that points at a staff record: real links to employees, plus the usual names for ones without a link
  FOR c IN
    SELECT DISTINCT tbl, col FROM (
      SELECT cl.relname::text AS tbl, a.attname::text AS col
      FROM pg_constraint fk JOIN pg_class cl ON cl.oid = fk.conrelid JOIN pg_namespace ns ON ns.oid = cl.relnamespace
      JOIN pg_attribute a ON a.attrelid = fk.conrelid AND a.attnum = fk.conkey[1]
      WHERE fk.contype = 'f' AND cl.relkind = 'r' AND fk.confrelid = 'public.employees'::regclass AND ns.nspname = 'public' AND array_length(fk.conkey, 1) = 1
      UNION
      SELECT ic.table_name::text, ic.column_name::text FROM information_schema.columns ic
      JOIN information_schema.tables it ON it.table_schema = ic.table_schema AND it.table_name = ic.table_name AND it.table_type = 'BASE TABLE'
      WHERE ic.table_schema = 'public' AND ic.data_type IN ('bigint', 'integer')
        AND ic.column_name IN ('employee_id', 'salesperson_id', 'sold_by_employee_id', 'performed_by_employee_id', 'technician_id', 'tech_id', 'lead_tech_id', 'assigned_employee_id')
    ) x WHERE NOT (tbl = 'employees')
  LOOP
    -- row by row, so a row that would become a duplicate (e.g. the same person twice on one visit) is dropped instead
    FOR r IN EXECUTE format('SELECT ctid AS t FROM public.%I WHERE %I = $1', c.tbl, c.col) USING p_from LOOP
      BEGIN
        EXECUTE format('UPDATE public.%I SET %I = $1 WHERE ctid = $2', c.tbl, c.col) USING p_to, r.t;
        n := n + 1;
      EXCEPTION WHEN unique_violation THEN
        EXECUTE format('DELETE FROM public.%I WHERE ctid = $1', c.tbl) USING r.t;
      END;
    END LOOP;
  END LOOP;
  UPDATE employees SET active = false WHERE id = p_from AND active IS DISTINCT FROM false;
  IF n > 0 THEN
    INSERT INTO audit_log (table_name, row_id, action, new_values)
    VALUES ('employees', p_from, 'update', jsonb_build_object('change', 'merged into staff record ' || p_to, 'rows_moved', n));
  END IF;
  RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public._merge_employee(bigint, bigint) FROM PUBLIC, anon, authenticated;

-- Randall Mackenzie (ServiceTitan sales manager record) is Randall M (his tech record, which his app login uses)
UPDATE public.employees SET merged_into = 12867323
WHERE id = 2321 AND merged_into IS NULL AND EXISTS (SELECT 1 FROM public.employees WHERE id = 12867323);

SELECT public._merge_employee(id, merged_into) FROM public.employees WHERE merged_into IS NOT NULL;

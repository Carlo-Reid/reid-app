-- Equipment we installed but with no install date (or ServiceTitan's 1900-01-01 "unknown"): the date comes from our install.
--  * an install job at the same address whose job type or invoice lines are for that kind of equipment (furnace, A/C, water heater…),
--  * and that install isn't already on another piece of the same kind there (dated from ~4 months before the install on),
--  * and it's the only undated piece of that kind there (or the only one marked "installed by us").
--  Equipment marked "installed by us" with no date and just one install job at the address gets that job's date.
-- Date = the install's invoice date (or the day the job was finished). It's also marked installed by us and linked to the job.
-- Safe to run again: only undated equipment is touched. _fill_install_dates(true) only reports what it would do.
CREATE OR REPLACE FUNCTION public._fill_install_dates(p_dry boolean DEFAULT true)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
DECLARE n int := 0; out jsonb;
BEGIN
  IF current_user NOT IN ('postgres', 'supabase_admin') AND public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'owners only'; END IF;
  CREATE TEMP TABLE _fid ON COMMIT DROP AS
  WITH inst AS (
    SELECT j.id AS job_id, j.location_id,
           coalesce(min(i.invoice_date), (j.completed_at AT TIME ZONE 'America/Toronto')::date) AS d,
           array_remove(array_agg(DISTINCT public._eq_kind(il.description)) || public._eq_kind(t.name), NULL) AS kinds
    FROM jobs j JOIN job_types t ON t.id = j.job_type_id AND t.job_class = 'install'
    LEFT JOIN invoices i ON i.job_id = j.id AND i.status NOT IN ('void', 'draft')
    LEFT JOIN invoice_lines il ON il.invoice_id = i.id
    WHERE j.status <> 'cancelled'
    GROUP BY j.id, j.location_id, t.name, j.completed_at),
  eq AS (
    SELECT e.id, e.location_id, e.installed_by_company AS ours, public._eq_kind(et.name) AS k, (e.install_date IS NULL OR e.install_date < DATE '1950-01-01') AS undated, e.install_date
    FROM equipment e JOIN equipment_types et ON et.id = e.equipment_type_id),
  -- 1) by kind
  bykind AS (
    SELECT DISTINCT ON (u.id) u.id, x.job_id, x.d, 'kind' AS why
    FROM eq u JOIN inst x ON x.location_id = u.location_id AND u.k = ANY (x.kinds) AND x.d IS NOT NULL
    WHERE u.undated AND u.k IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM eq o WHERE o.location_id = u.location_id AND o.id <> u.id AND o.k = u.k AND NOT o.undated AND o.install_date >= x.d - 120)
      AND (   (SELECT count(*) FROM eq o WHERE o.location_id = u.location_id AND o.k = u.k AND o.undated) = 1
           OR (u.ours AND (SELECT count(*) FROM eq o WHERE o.location_id = u.location_id AND o.k = u.k AND o.undated AND o.ours) = 1))
    ORDER BY u.id, x.d DESC),
  -- 2) marked "installed by us", one install job at the address
  byone AS (
    SELECT u.id, (SELECT x.job_id FROM inst x WHERE x.location_id = u.location_id) AS job_id, (SELECT x.d FROM inst x WHERE x.location_id = u.location_id) AS d, 'only install' AS why
    FROM eq u WHERE u.undated AND u.ours AND NOT EXISTS (SELECT 1 FROM bykind b WHERE b.id = u.id)
      AND (SELECT count(*) FROM inst x WHERE x.location_id = u.location_id AND x.d IS NOT NULL) = 1)
  SELECT * FROM bykind UNION ALL SELECT * FROM byone WHERE d IS NOT NULL;

  SELECT jsonb_build_object('count', count(*), 'by_kind', count(*) FILTER (WHERE why = 'kind'), 'by_only_install', count(*) FILTER (WHERE why = 'only install'),
    'sample', (SELECT jsonb_agg(s) FROM (SELECT f.id, f.why, f.d, et.name AS type, e.model_number, l.street, t.name AS job_type
                 FROM _fid f JOIN equipment e ON e.id = f.id JOIN equipment_types et ON et.id = e.equipment_type_id LEFT JOIN locations l ON l.id = e.location_id
                 LEFT JOIN jobs j ON j.id = f.job_id LEFT JOIN job_types t ON t.id = j.job_type_id ORDER BY f.d DESC LIMIT 25) s))
  INTO out FROM _fid;
  IF NOT p_dry THEN
    UPDATE equipment e SET install_date = f.d, install_job_id = f.job_id, installed_by_company = true, updated_at = now() FROM _fid f WHERE e.id = f.id;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN INSERT INTO audit_log (table_name, row_id, action, new_values)
      SELECT 'equipment', f.id, 'update', jsonb_build_object('install_date', f.d, 'install_job_id', f.job_id, 'why', 'install date from our install (' || f.why || ')') FROM _fid f; END IF;
    out := out || jsonb_build_object('updated', n);
  END IF;
  RETURN out;
END $function$;
REVOKE EXECUTE ON FUNCTION public._fill_install_dates(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._fill_install_dates(boolean) TO authenticated;
NOTIFY pgrst, 'reload schema';

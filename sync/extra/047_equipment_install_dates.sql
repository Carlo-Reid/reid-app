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
  DROP TABLE IF EXISTS _fid, _feq, _finst;
  -- the equipment, with its kind (furnace, A/C, water heater…) and whether it has a real date
  CREATE TEMP TABLE _feq ON COMMIT DROP AS
    SELECT e.id, e.location_id, e.installed_by_company AS ours, public._eq_kind(et.name) AS k,
           (e.install_date IS NULL OR e.install_date < DATE '1950-01-01') AS undated, e.install_date
    FROM equipment e JOIN equipment_types et ON et.id = e.equipment_type_id;
  CREATE INDEX ON _feq (location_id, k); ANALYZE _feq;
  -- our installs at the addresses that have undated equipment: their date and the kinds on them
  CREATE TEMP TABLE _finst ON COMMIT DROP AS
    WITH locs AS (SELECT DISTINCT location_id FROM _feq WHERE undated),
    j AS (SELECT j.id, j.location_id, j.completed_at, t.name AS tname FROM jobs j JOIN job_types t ON t.id = j.job_type_id AND t.job_class = 'install'
          WHERE j.status <> 'cancelled' AND j.location_id IN (SELECT location_id FROM locs)),
    iv AS (SELECT i.id, i.job_id, i.invoice_date FROM invoices i WHERE i.job_id IN (SELECT id FROM j) AND i.status NOT IN ('void', 'draft'))
    SELECT j.id AS job_id, j.location_id,
           coalesce((SELECT min(iv.invoice_date) FROM iv WHERE iv.job_id = j.id), (j.completed_at AT TIME ZONE 'America/Toronto')::date) AS d,
           array_remove(ARRAY(SELECT DISTINCT public._eq_kind(il.description) FROM iv JOIN invoice_lines il ON il.invoice_id = iv.id WHERE iv.job_id = j.id) || public._eq_kind(j.tname), NULL) AS kinds
    FROM j;
  CREATE INDEX ON _finst (location_id); ANALYZE _finst;
  CREATE TEMP TABLE _fid ON COMMIT DROP AS
  WITH bykind AS (
    SELECT DISTINCT ON (u.id) u.id, x.job_id, x.d, 'kind' AS why
    FROM _feq u JOIN _finst x ON x.location_id = u.location_id AND u.k = ANY (x.kinds) AND x.d IS NOT NULL
    WHERE u.undated AND u.k IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM _feq o WHERE o.location_id = u.location_id AND o.k = u.k AND o.id <> u.id AND NOT o.undated AND o.install_date >= x.d - 120)
      AND (   (SELECT count(*) FROM _feq o WHERE o.location_id = u.location_id AND o.k = u.k AND o.undated) = 1
           OR (u.ours AND (SELECT count(*) FROM _feq o WHERE o.location_id = u.location_id AND o.k = u.k AND o.undated AND o.ours) = 1))
    ORDER BY u.id, x.d DESC),
  byone AS (
    SELECT u.id, x.job_id, x.d, 'only install' AS why
    FROM _feq u JOIN _finst x ON x.location_id = u.location_id AND x.d IS NOT NULL
    WHERE u.undated AND u.ours AND NOT EXISTS (SELECT 1 FROM bykind b WHERE b.id = u.id)
      AND (SELECT count(*) FROM _finst y WHERE y.location_id = u.location_id AND y.d IS NOT NULL) = 1)
  SELECT * FROM bykind UNION ALL SELECT * FROM byone;
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
CREATE TABLE IF NOT EXISTS public.fix_reports (name text PRIMARY KEY, report jsonb, made_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.fix_reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS owner_read ON public.fix_reports;
CREATE POLICY owner_read ON public.fix_reports FOR SELECT TO authenticated USING ((SELECT public.current_staff_role()) = 'owner');
GRANT SELECT ON public.fix_reports TO authenticated;
-- tonight's check (report only; nothing is changed until it's switched on)
INSERT INTO public.fix_reports (name, report) VALUES ('install_dates_preview', public._fill_install_dates(true))
ON CONFLICT (name) DO UPDATE SET report = EXCLUDED.report, made_at = now();
GRANT EXECUTE ON FUNCTION public._fill_install_dates(boolean) TO authenticated;
NOTIFY pgrst, 'reload schema';

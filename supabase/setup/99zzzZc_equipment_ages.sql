-- 99zzzZc: age of the equipment on the Sales page. Also runs every night from sync/extra/043_equipment_ages.sql. Safe to run more than once.
-- Age of the equipment at the home of each sales job (Sales page, Carlo view, customer page).
-- For each job: the main equipment that was there before the sale (installed before the job was made, and still in, or taken out after that),
-- the newest of each kind (so a duplicate old record doesn't win), with its install date. The page works out "18 yrs".
CREATE OR REPLACE FUNCTION public._eq_kind(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  SELECT CASE WHEN t ~* '(coil|tin package|oil tank|trim|kit|module|liner|surround|return air|sensor|circ|condensate)' THEN NULL
              WHEN t ~* 'heat ?pump' THEN 'Heat pump'
              WHEN t ~* '(tank|water h|water  h|hwt|hot wat|tnkls|tankless)' THEN 'Water heater'
              WHEN t ~* 'boil' THEN 'Boiler'
              WHEN t ~* 'furna' THEN 'Furnace'
              WHEN t ~* '(a/c|(^|[^a-z])ac([^a-z]|$)|air con|air cont|^13acx|^rac13|ycd|ycg)' THEN 'A/C'
              WHEN t ~* '(fire ?p|firplace|firepalce)' THEN 'Fireplace' END
$function$;
CREATE OR REPLACE FUNCTION public.sales_equipment_ages(p_jobs bigint[])
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('job_id', x.job_id, 'kind', x.kind, 'd', x.install_date, 'gone', x.gone) ORDER BY x.job_id, x.ord)
    FROM (SELECT DISTINCT ON (j.id, k.kind) j.id AS job_id, k.kind, e.install_date, e.status <> 'active' AS gone,
                 array_position(ARRAY['Furnace', 'A/C', 'Heat pump', 'Boiler', 'Water heater', 'Fireplace'], k.kind) AS ord
          FROM jobs j
          JOIN equipment e ON e.location_id = j.location_id
          JOIN equipment_types t ON t.id = e.equipment_type_id
          CROSS JOIN LATERAL (SELECT public._eq_kind(t.name) AS kind) k
          WHERE j.id = ANY (p_jobs) AND k.kind IS NOT NULL AND e.install_date IS NOT NULL
            AND e.install_date < coalesce(j.created_at::date, current_date + 1)
            AND (e.status = 'active' OR e.removed_on IS NULL OR e.removed_on >= j.created_at::date)
          ORDER BY j.id, k.kind, e.install_date DESC) x), '[]'::jsonb) END
$function$;
REVOKE EXECUTE ON FUNCTION public.sales_equipment_ages(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_equipment_ages(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

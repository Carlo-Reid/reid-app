-- Photos and files: who took them. ServiceTitan doesn't say, so it's the tech(s) on that job's call the day the photo was taken
-- (or, if no call that day, the techs on the job).
DROP FUNCTION IF EXISTS public.customer_files(bigint, bigint, int);
CREATE OR REPLACE FUNCTION public.customer_files(p_customer bigint, p_location bigint DEFAULT NULL, p_limit int DEFAULT 400)
RETURNS TABLE (id bigint, job_id bigint, job_number text, job_date date, job_type text, file_name text, storage_key text, thumb_key text,
               mime_type text, size_bytes bigint, category text, taken_at timestamptz, total_count bigint, taken_by text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH f AS (
    SELECT a.id, j.id AS job_id, j.job_number, (coalesce(j.completed_at, j.created_at) AT TIME ZONE 'America/Toronto')::date AS job_date, t.name AS job_type,
           a.file_name, a.storage_key, a.thumb_key, a.mime_type, a.size_bytes, a.category, a.taken_at, count(*) OVER () AS total_count, j.created_at AS jc
    FROM jobs j
    JOIN attachments a ON a.entity_type = 'job' AND a.entity_id = j.id
    LEFT JOIN job_types t ON t.id = j.job_type_id
    WHERE public.current_staff_role() IS NOT NULL
      AND j.customer_id = p_customer AND (p_location IS NULL OR j.location_id = p_location)
    ORDER BY coalesce(a.taken_at, j.created_at) DESC, a.id DESC
    LIMIT least(coalesce(p_limit, 400), 2000))
  SELECT f.id, f.job_id, f.job_number, f.job_date, f.job_type, f.file_name, f.storage_key, f.thumb_key, f.mime_type, f.size_bytes, f.category, f.taken_at, f.total_count,
         coalesce(
           (SELECT string_agg(DISTINCT nullif(btrim(regexp_replace(concat_ws(' ', e.first_name, e.last_name), '\(former staff\)|^zpast-', '', 'gi')), ''), ', ')
              FROM visits v JOIN visit_assignments va ON va.visit_id = v.id JOIN employees e ON e.id = va.employee_id
             WHERE v.job_id = f.job_id AND f.taken_at IS NOT NULL AND v.scheduled_date = (f.taken_at AT TIME ZONE 'America/Toronto')::date),
           (SELECT string_agg(DISTINCT nullif(btrim(regexp_replace(concat_ws(' ', e.first_name, e.last_name), '\(former staff\)|^zpast-', '', 'gi')), ''), ', ')
              FROM visits v JOIN visit_assignments va ON va.visit_id = v.id JOIN employees e ON e.id = va.employee_id
             WHERE v.job_id = f.job_id))
  FROM f
  ORDER BY coalesce(f.taken_at, f.jc) DESC, f.id DESC
$$;
REVOKE EXECUTE ON FUNCTION public.customer_files(bigint, bigint, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_files(bigint, bigint, int) TO authenticated;
NOTIFY pgrst, 'reload schema';

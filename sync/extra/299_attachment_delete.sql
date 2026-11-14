-- Carlo, Nov 14: "have a way for me to delete pictures from customer files". It is a hide, not a real delete (the same way a
-- cancelled P.O. or a taken-off packing slip mark is kept, not erased): the file stays in storage and the row stays in the
-- attachments table, just marked hidden, with an Undo. A picture synced from ServiceTitan (st_id set) could in theory come
-- back if ServiceTitan's own sync writes to it again, but the sync's upsert only touches the columns it sends -- deleted_at
-- and deleted_by are never in that list -- so a hidden picture stays hidden across a resync.
ALTER TABLE public.attachments ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE public.attachments ADD COLUMN IF NOT EXISTS deleted_by bigint;

-- customer_files leaves out anything hidden
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
      AND a.deleted_at IS NULL
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

-- hide (or un-hide) a picture or file: office people and owners, the same as call recordings (_rec_ok)
CREATE OR REPLACE FUNCTION public.attachment_delete(p_id bigint, p_on boolean DEFAULT true) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_job bigint; v_name text;
BEGIN
  IF NOT public._rec_ok() THEN RAISE EXCEPTION 'Only office people and owners can delete a file'; END IF;
  SELECT entity_id, file_name INTO v_job, v_name FROM attachments WHERE id = p_id AND entity_type = 'job';
  IF v_job IS NULL THEN RAISE EXCEPTION 'That file is gone'; END IF;
  IF p_on THEN
    UPDATE attachments SET deleted_at = now(), deleted_by = public.current_app_user_id() WHERE id = p_id;
    PERFORM public.add_note('job', v_job, 'Deleted a file: ' || coalesce(v_name, 'file'));
  ELSE
    UPDATE attachments SET deleted_at = NULL, deleted_by = NULL WHERE id = p_id;
    PERFORM public.add_note('job', v_job, 'Put a deleted file back: ' || coalesce(v_name, 'file'));
  END IF;
  RETURN jsonb_build_object('ok', true);
END $f$;
REVOKE EXECUTE ON FUNCTION public.attachment_delete(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.attachment_delete(bigint, boolean) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Carlo, Nov 14, 2026: "on the To be Booked page have future walks listed on the page as waiting and if a tech arrives and starts to work
-- have anything he does show up on it live so if he takes pictures have them show up there." walk_to_book (277_walk_done.sql) only ever
-- showed a walk once it was DONE. This adds the other two states, read by the same page: a walk still waiting for its day (status
-- scheduled), and a walk a tech is on right now (en_route / on_site), with whatever pictures are saved on it so far -- they show up here
-- as soon as the tech takes them, because walk_answer_set / walk_extra_photo_add save each picture the moment it's taken, not at the end.
CREATE OR REPLACE FUNCTION public.walk_upcoming() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (public.has_permission('calls.book') OR public.has_permission('calls.dispatch') OR public.current_staff_role() = 'owner') THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY CASE x ->> 'status' WHEN 'on_site' THEN 0 WHEN 'en_route' THEN 1 ELSE 2 END, x ->> 'scheduled_date', x ->> 'arrival_start') FROM (
    SELECT jsonb_build_object('visit_id', v.id, 'job_id', j.id, 'job_number', j.job_number, 'job_type', t.name, 'what', v.visit_purpose,
      'customer_id', c.id, 'customer', c.display_name, 'address', concat_ws(', ', l.street, 'Unit ' || nullif(btrim(l.unit), ''), l.city),
      'status', v.status, 'scheduled_date', v.scheduled_date, 'arrival_start', v.arrival_start, 'arrival_end', v.arrival_end, 'arrived_at', v.arrived_at,
      'tech', (SELECT string_agg(public._emp_name(va.employee_id), ' and ' ORDER BY (va.role <> 'lead'), va.id) FROM visit_assignments va WHERE va.visit_id = v.id),
      'total_q', (SELECT CASE WHEN to_regprocedure('public.walk_questions()') IS NOT NULL THEN jsonb_array_length(public.walk_questions()) ELSE 0 END),
      'answers', (SELECT coalesce(jsonb_agg(jsonb_build_object('q', a.q, 'question', a.question, 'na', a.na, 'key', a.storage_key) ORDER BY a.q), '[]'::jsonb) FROM walk_answers a WHERE a.visit_id = v.id AND a.q < 1000),
      'extra', (SELECT coalesce(jsonb_agg(a.storage_key ORDER BY a.q), '[]'::jsonb) FROM walk_answers a WHERE a.visit_id = v.id AND a.q >= 1000)) AS x
    FROM visits v
    JOIN jobs j ON j.id = v.job_id
    JOIN job_types t ON t.id = j.job_type_id
    JOIN customers c ON c.id = j.customer_id
    JOIN locations l ON l.id = j.location_id
    WHERE v.visit_purpose ILIKE 'walk%' AND v.status IN ('scheduled', 'unscheduled', 'en_route', 'on_site')
      AND j.status NOT IN ('cancelled', 'closed')
      AND NOT EXISTS (SELECT 1 FROM walk_results w WHERE w.visit_id = v.id)) s), '[]'::jsonb);
END $function$;
REVOKE EXECUTE ON FUNCTION public.walk_upcoming() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.walk_upcoming() TO authenticated;
NOTIFY pgrst, 'reload schema';

-- What is being installed on a call: the equipment, parts and materials on the job's invoices (names only, no prices).
-- Carlo, Nov 19, 2026: the tech's call on Tech Calls says what the call is for at the top, and the equipment or part being installed.
CREATE OR REPLACE FUNCTION public.call_items(p_visit_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._install_ok(p_visit_id) THEN NULL ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('name', p.name, 'sku', p.sku, 'model', p.model_number, 'type', p.item_type, 'qty', il.quantity)
                     ORDER BY (p.item_type = 'equipment') DESC, i.id, il.sequence, il.id)
    FROM visits v JOIN invoices i ON i.job_id = v.job_id JOIN invoice_lines il ON il.invoice_id = i.id JOIN pricebook_items p ON p.id = il.item_id
    WHERE v.id = p_visit_id AND i.status <> 'void' AND i.store_copy_of IS NULL AND i.deleted_at IS NULL
      AND p.item_type IN ('equipment', 'service', 'material') AND il.kit_parent_line_id IS NULL), '[]'::jsonb) END $f$;
REVOKE EXECUTE ON FUNCTION public.call_items(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.call_items(bigint) TO authenticated;

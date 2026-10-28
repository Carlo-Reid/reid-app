-- Job costing: take a line out of the costs (greyed out, not counted, never deleted), with who did it and when.
CREATE TABLE IF NOT EXISTS public.invoice_line_cost_skips (
  line_id bigint PRIMARY KEY,
  invoice_id bigint,
  skipped_by bigint,
  skipped_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.invoice_line_cost_skips ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.invoice_line_cost_skips FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.inv_line_cost_skip(p_line bigint, p_skip boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_inv bigint; v_desc text;
BEGIN
  IF NOT (public._can_cost() OR public.has_permission('jobs.costing')) THEN RAISE EXCEPTION 'You don''t have permission to change job costing'; END IF;
  SELECT invoice_id, split_part(description, E'\n', 1) INTO v_inv, v_desc FROM invoice_lines WHERE id = p_line;
  IF v_inv IS NULL THEN RAISE EXCEPTION 'That line no longer exists'; END IF;
  IF p_skip THEN
    INSERT INTO invoice_line_cost_skips (line_id, invoice_id, skipped_by) VALUES (p_line, v_inv, public.current_app_user_id()) ON CONFLICT (line_id) DO NOTHING;
  ELSE
    DELETE FROM invoice_line_cost_skips WHERE line_id = p_line;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('invoices', v_inv, 'update', public.current_app_user_id(), jsonb_build_object('job_costing_line', left(v_desc, 120), 'counted', NOT p_skip));
END $function$;
REVOKE EXECUTE ON FUNCTION public.inv_line_cost_skip(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inv_line_cost_skip(bigint, boolean) TO authenticated;

-- the costing: a taken-out line's cost and hours aren't counted; each line says who took it out
SELECT public._patch_fn('inv_costing', $o$'equip', coalesce(equip, false))$o$,
  $n$'equip', coalesce(equip, false), 'skip', (SELECT jsonb_build_object('by', public._staff_name(s.skipped_by), 'at', s.skipped_at) FROM invoice_line_cost_skips s WHERE s.line_id = ln.id))$n$);
SELECT public._patch_fn('inv_costing', $o$'est_hours', (SELECT coalesce(sum(hrs), 0) FROM ln),$o$,
  $n$'est_hours', (SELECT coalesce(sum(hrs), 0) FROM ln WHERE NOT EXISTS (SELECT 1 FROM invoice_line_cost_skips s WHERE s.line_id = ln.id)),$n$);
NOTIFY pgrst, 'reload schema';

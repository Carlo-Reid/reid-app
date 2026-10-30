-- A proposal can be changed as a new version: a copy (same customer, job, options and lines) that opens as a draft.
-- The original stays exactly as it was (sold, not sold, sent or old), so what the customer was given is never changed.
ALTER TABLE public.estimates ADD COLUMN IF NOT EXISTS version_of bigint REFERENCES public.estimates(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS estimates_version_of ON public.estimates (version_of);

CREATE OR REPLACE FUNCTION public.est_new_version(p_id bigint)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE e estimates; v_id bigint; v_base text; v_n int; o record; v_opt bigint;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT * INTO e FROM estimates WHERE id = p_id; IF e.id IS NULL THEN RAISE EXCEPTION 'That proposal no longer exists'; END IF;
  v_base := regexp_replace(coalesce(e.estimate_number, 'E' || e.id), '-v\d+$', '');
  SELECT 1 + count(*) INTO v_n FROM estimates WHERE estimate_number = v_base OR (left(estimate_number, length(v_base) + 2) = v_base || '-v' AND substr(estimate_number, length(v_base) + 3) ~ '^\d+$');
  INSERT INTO estimates (estimate_number, job_id, project_id, customer_id, location_id, business_unit_id, partner_id, use_partner_branding, sold_by_employee_id,
                         created_via, recipient_type, recipient_partner_contact_id, recipient_email, status, version_of)
  VALUES (v_base || '-v' || greatest(v_n, 2), e.job_id, e.project_id, e.customer_id, e.location_id, e.business_unit_id, e.partner_id, e.use_partner_branding,
          coalesce(e.sold_by_employee_id, public._my_employee()), 'version', e.recipient_type, e.recipient_partner_contact_id, e.recipient_email, 'draft', e.id)
  RETURNING id INTO v_id;
  FOR o IN SELECT * FROM estimate_options WHERE estimate_id = p_id ORDER BY sequence, id LOOP
    INSERT INTO estimate_options (estimate_id, sequence, name, description, is_recommended) VALUES (v_id, o.sequence, o.name, o.description, o.is_recommended) RETURNING id INTO v_opt;
    INSERT INTO estimate_lines (estimate_option_id, sequence, item_id, description, quantity, unit_price, unit_cost, est_labour_hours, taxable, kit_skip, long_desc, line_kind)
    SELECT v_opt, row_number() OVER (ORDER BY l.sequence, l.id), l.item_id, l.description, l.quantity, l.unit_price, l.unit_cost, l.est_labour_hours, l.taxable, l.kit_skip, l.long_desc, l.line_kind
      FROM estimate_lines l WHERE l.estimate_option_id = o.id AND l.parent_line_id IS NULL
       AND (l.offer_expires_at IS NULL OR l.offer_expires_at > now());   -- a timed offer that ran out doesn't come along
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM estimate_options WHERE estimate_id = v_id) THEN
    INSERT INTO estimate_options (estimate_id, sequence, name, is_recommended) VALUES (v_id, 1, 'Option 1', true);
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('estimates', v_id, 'insert', public.current_app_user_id(), jsonb_build_object('version_of', p_id, 'from_number', e.estimate_number));
  RETURN v_id;
END $function$;
REVOKE EXECUTE ON FUNCTION public.est_new_version(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_new_version(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

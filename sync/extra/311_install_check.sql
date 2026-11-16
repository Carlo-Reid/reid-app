-- Carlo, Nov 16, 2026, 6:09 p.m.: "when a tech opens the tech calls and he has an install then the page should open a box saying the details of
-- the install and asking him to please take a picture of the equipment bar code to proceed and then it confirms the model on the invoice
-- matches the picture and it loads the serial number up then let them continue."
-- One row for each piece of equipment checked on an install call. The picture is a job photo (it is in the customer's Photos and files).
CREATE TABLE IF NOT EXISTS public.install_checks (
  id bigserial PRIMARY KEY,
  visit_id bigint NOT NULL REFERENCES visits(id) ON DELETE CASCADE,
  job_id bigint NOT NULL,
  invoice_id bigint,
  line_id bigint,
  item_id bigint,
  model_expected text,
  model_read text,
  matched boolean NOT NULL DEFAULT false,
  by_hand boolean NOT NULL DEFAULT false,
  serial text,
  read_text text,
  storage_key text,
  attachment_id bigint,
  equipment_id bigint,
  at timestamptz NOT NULL DEFAULT now(),
  by_user bigint
);
CREATE INDEX IF NOT EXISTS install_checks_visit ON public.install_checks (visit_id);
ALTER TABLE public.install_checks ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public._install_ok(p_visit_id bigint) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT public.current_staff_role() IS NOT NULL AND (public.has_permission('calls.dispatch') OR public.has_permission('calls.book') OR public.current_staff_role() = 'owner'
    OR EXISTS (SELECT 1 FROM visit_assignments WHERE visit_id = p_visit_id AND employee_id = public.my_employee_id())) $f$;
REVOKE EXECUTE ON FUNCTION public._install_ok(bigint) FROM PUBLIC, anon;

-- the install's details, the equipment on the job's invoices, and what is already checked
CREATE OR REPLACE FUNCTION public.install_check_info(p_visit_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v visits;
BEGIN
  IF NOT public._install_ok(p_visit_id) THEN RETURN NULL; END IF;
  SELECT * INTO v FROM visits WHERE id = p_visit_id;
  IF v.id IS NULL THEN RETURN NULL; END IF;
  RETURN (SELECT jsonb_build_object('visit_id', v.id, 'job_id', j.id, 'job_number', j.job_number, 'job_type', t.name, 'what', v.visit_purpose,
      'customer', c.display_name, 'address', concat_ws(', ', l.street, 'Unit ' || nullif(btrim(l.unit), ''), l.city),
      'items', coalesce((SELECT jsonb_agg(jsonb_build_object('line_id', il.id, 'invoice_id', i.id, 'invoice', i.invoice_number, 'item_id', p.id,
          'name', p.name, 'sku', p.sku, 'model', p.model_number, 'maker', p.manufacturer, 'qty', il.quantity,
          'done', (SELECT jsonb_build_object('serial', k.serial, 'matched', k.matched, 'by_hand', k.by_hand, 'model_read', k.model_read, 'at', k.at)
                   FROM install_checks k WHERE k.visit_id = v.id AND k.line_id = il.id ORDER BY k.id DESC LIMIT 1)) ORDER BY i.id, il.sequence, il.id)
        FROM invoices i JOIN invoice_lines il ON il.invoice_id = i.id JOIN pricebook_items p ON p.id = il.item_id
        WHERE i.job_id = j.id AND i.status <> 'void' AND i.store_copy_of IS NULL AND i.deleted_at IS NULL
          AND p.item_type = 'equipment' AND il.kit_parent_line_id IS NULL), '[]'::jsonb))
    FROM jobs j JOIN job_types t ON t.id = j.job_type_id JOIN customers c ON c.id = j.customer_id JOIN locations l ON l.id = j.location_id
    WHERE j.id = v.job_id);
END $function$;
REVOKE EXECUTE ON FUNCTION public.install_check_info(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.install_check_info(bigint) TO authenticated;

-- save one check: the picture of the label (a job photo), what was read, the serial number
CREATE OR REPLACE FUNCTION public.install_check_save(p_visit_id bigint, p_line_id bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v visits; il invoice_lines; it pricebook_items; j jobs; v_key text := nullif(btrim(p ->> 'key'), ''); v_att bigint; v_eq bigint;
  v_serial text := nullif(upper(btrim(regexp_replace(coalesce(p ->> 'serial', ''), '\s+', '', 'g'))), '');
  v_match boolean := coalesce((p ->> 'matched')::boolean, false); v_hand boolean := coalesce((p ->> 'by_hand')::boolean, false);
  v_model text; v_id bigint;
BEGIN
  IF NOT public._install_ok(p_visit_id) THEN RAISE EXCEPTION 'You can only do this for a call you are on'; END IF;
  SELECT * INTO v FROM visits WHERE id = p_visit_id;
  IF v.id IS NULL THEN RAISE EXCEPTION 'That call no longer exists'; END IF;
  SELECT * INTO il FROM invoice_lines WHERE id = p_line_id;
  IF il.id IS NULL OR NOT EXISTS (SELECT 1 FROM invoices i WHERE i.id = il.invoice_id AND i.job_id = v.job_id) THEN RAISE EXCEPTION 'That line is not on this job''s invoice'; END IF;
  SELECT * INTO it FROM pricebook_items WHERE id = il.item_id;
  SELECT * INTO j FROM jobs WHERE id = v.job_id;
  IF v_serial IS NULL THEN RAISE EXCEPTION 'Type the serial number'; END IF;
  IF length(v_serial) > 40 THEN RAISE EXCEPTION 'That serial number is too long'; END IF;
  IF v_key IS NOT NULL AND v_key NOT LIKE 'forms/' || v.job_id || '/install-%' THEN RAISE EXCEPTION 'Take the picture again'; END IF;
  IF v_key IS NULL AND NOT v_hand THEN RAISE EXCEPTION 'Take a picture of the label first'; END IF;
  v_model := coalesce(nullif(btrim(it.model_number), ''), it.sku, it.name);
  IF v_key IS NOT NULL THEN
    INSERT INTO attachments (entity_type, entity_id, category, file_name, storage_key, mime_type, size_bytes, caption, taken_by_employee_id, taken_at)
    VALUES ('job', v.job_id, 'photo', 'Equipment label.jpg', v_key, 'image/jpeg', nullif(p ->> 'size', '')::bigint,
            'Install: the label of ' || v_model || ' · serial number ' || v_serial, public.my_employee_id(), now())
    RETURNING id INTO v_att;
  END IF;
  -- the customer's equipment record, when the price book item says what type of equipment it is
  IF it.equipment_type_id IS NOT NULL THEN
    SELECT e.id INTO v_eq FROM equipment e WHERE e.install_job_id = v.job_id AND e.pricebook_item_id = it.id AND e.status = 'active' ORDER BY e.id LIMIT 1;
    IF v_eq IS NULL THEN
      INSERT INTO equipment (location_id, equipment_type_id, manufacturer_id, pricebook_item_id, model_number, serial_number, install_date, installed_by_company, install_job_id)
      VALUES (j.location_id, it.equipment_type_id, it.manufacturer_id, it.id, v_model, v_serial, coalesce(v.scheduled_date, current_date), true, v.job_id)
      RETURNING id INTO v_eq;
    ELSE
      UPDATE equipment SET serial_number = v_serial, model_number = coalesce(nullif(btrim(model_number), ''), v_model) WHERE id = v_eq;
    END IF;
  END IF;
  INSERT INTO install_checks (visit_id, job_id, invoice_id, line_id, item_id, model_expected, model_read, matched, by_hand, serial, read_text, storage_key, attachment_id, equipment_id, by_user)
  VALUES (v.id, v.job_id, il.invoice_id, il.id, it.id, v_model, nullif(left(btrim(coalesce(p ->> 'model_read', '')), 80), ''), v_match, v_hand, v_serial,
          nullif(left(coalesce(p ->> 'text', ''), 4000), ''), v_key, v_att, v_eq, public.current_app_user_id())
  RETURNING id INTO v_id;
  INSERT INTO notes (entity_type, entity_id, body, author_user_id, source)
  VALUES ('job', v.job_id, 'Install check: ' || v_model || ', serial number ' || v_serial || '. '
    || CASE WHEN v_hand THEN 'The label could not be photographed: the serial number was typed by hand. The model was NOT checked against the label.'
            WHEN v_match THEN 'The model on the label matches the invoice.'
            ELSE 'WARNING: the model on the invoice was NOT found on the label picture. The tech went on anyway. Look at the picture in the job''s photos.' END, public.current_app_user_id(), 'call');
  RETURN jsonb_build_object('id', v_id, 'equipment_id', v_eq);
END $function$;
REVOKE EXECUTE ON FUNCTION public.install_check_save(bigint, bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.install_check_save(bigint, bigint, jsonb) TO authenticated;

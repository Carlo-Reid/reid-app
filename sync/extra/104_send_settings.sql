-- =====================================================================
-- Improvement 4: the Sending page (owners): switch sending from Test (everything comes to you) to Live (to customers),
-- change the test address, and fill in staff cell numbers (texts in test mode go to the sender's own cell).
-- Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.send_settings()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RETURN NULL; END IF;
  SELECT jsonb_build_object(
    'test_to', (SELECT nullif(btrim(send_test_to), '') FROM company_settings ORDER BY id LIMIT 1),
    'me', (SELECT employee_id FROM app_users WHERE id = public.current_app_user_id()),
    'sent', (SELECT jsonb_build_object('test', count(*) FILTER (WHERE test), 'live', count(*) FILTER (WHERE NOT test)) FROM doc_sends WHERE status = 'sent'),
    'staff', coalesce((SELECT jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', concat_ws(' ', e.first_name, e.last_name), 'role', u.role,
                         'cell', nullif(btrim(e.mobile_phone), ''), 'login', u.login_email) ORDER BY (nullif(btrim(e.mobile_phone), '') IS NOT NULL), lower(e.first_name), lower(e.last_name))
                       FROM app_users u JOIN employees e ON e.id = u.employee_id
                       WHERE u.active AND u.deleted_at IS NULL AND coalesce(e.active, true)), '[]'))
  INTO v;
  RETURN v;
END $$;

-- p_test_to: an email = Test mode (everything goes there); empty = Live (to customers)
CREATE OR REPLACE FUNCTION public.set_send_mode(p_test_to text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE t text := nullif(lower(btrim(coalesce(p_test_to, ''))), ''); old text; cs bigint;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can change this'; END IF;
  IF t IS NOT NULL AND t !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' THEN RAISE EXCEPTION 'That email doesn''t look right'; END IF;
  SELECT id, send_test_to INTO cs, old FROM company_settings ORDER BY id LIMIT 1;
  IF cs IS NULL THEN RAISE EXCEPTION 'The company settings are missing'; END IF;
  UPDATE company_settings SET send_test_to = t, updated_at = now() WHERE id = cs;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('company_settings', cs, 'send_mode', public.current_app_user_id(), jsonb_build_object('send_test_to', old), jsonb_build_object('send_test_to', t));
  RETURN jsonb_build_object('test_to', t);
END $$;

CREATE OR REPLACE FUNCTION public.set_staff_cell(p_employee bigint, p_cell text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d text := right(regexp_replace(coalesce(p_cell, ''), '\D', '', 'g'), 10);
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only an owner can change this'; END IF;
  IF btrim(coalesce(p_cell, '')) <> '' AND length(d) <> 10 THEN RAISE EXCEPTION 'A cell number has 10 digits'; END IF;
  UPDATE employees SET mobile_phone = nullif(d, ''), updated_at = now() WHERE id = p_employee;
  IF NOT FOUND THEN RAISE EXCEPTION 'That person isn''t on the staff list'; END IF;
  RETURN nullif(d, '');
END $$;

REVOKE EXECUTE ON FUNCTION public.send_settings(), public.set_send_mode(text), public.set_staff_cell(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_settings(), public.set_send_mode(text), public.set_staff_cell(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

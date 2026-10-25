-- Test mode for sending to customers: a test text number (company_settings.send_test_phone), set from the Settings page.
-- While test mode is on (send_test_to has an email), emails go to that email and texts to send_test_phone (or the sender's own cell).
-- Safe to run more than once.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'company_settings' AND column_name = 'send_test_phone') THEN
    ALTER TABLE public.company_settings ADD COLUMN send_test_phone text;
    UPDATE public.company_settings SET send_test_phone = '6132982948' WHERE true;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.doc_send_start(p_kind text, p_ref bigint, p_customer bigint, p_title text, p_channel text, p_to text, p_subject text, p_body text,
                                                 p_with_pdf boolean, p_pdf_b64 text, p_file_name text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_test text; v_to text; v_send text; v_cust bigint; r doc_sends;
BEGIN
  IF NOT public.has_permission('email.send') THEN RAISE EXCEPTION 'You don''t have permission to send to customers'; END IF;
  IF p_channel NOT IN ('email', 'text') THEN RAISE EXCEPTION 'Email or text?'; END IF;
  IF p_kind = 'estimate' AND NOT EXISTS (SELECT 1 FROM estimates WHERE id = p_ref) THEN RAISE EXCEPTION 'That estimate no longer exists'; END IF;
  IF p_kind = 'invoice' AND NOT EXISTS (SELECT 1 FROM invoices WHERE id = p_ref) THEN RAISE EXCEPTION 'That invoice no longer exists'; END IF;
  v_cust := public._doc_customer(p_kind, p_ref, p_customer);
  SELECT nullif(btrim(send_test_to), '') INTO v_test FROM company_settings ORDER BY id LIMIT 1;
  IF p_channel = 'email' THEN
    v_to := lower(btrim(coalesce(p_to, '')));
    IF v_to !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN RAISE EXCEPTION 'That email address doesn''t look right: %', p_to; END IF;
    v_send := coalesce(lower(v_test), v_to);
  ELSE
    v_to := right(regexp_replace(coalesce(p_to, ''), '\D', '', 'g'), 10);
    IF length(v_to) <> 10 THEN RAISE EXCEPTION 'That phone number doesn''t look right: %', p_to; END IF;
    IF v_test IS NOT NULL THEN   -- test mode: the text goes to the test number (Settings), or else the sender's own cell
      SELECT right(regexp_replace(coalesce(send_test_phone, ''), '\D', '', 'g'), 10) INTO v_send FROM company_settings ORDER BY id LIMIT 1;
      IF coalesce(length(v_send), 0) <> 10 THEN
        SELECT right(regexp_replace(coalesce(em.mobile_phone, ''), '\D', '', 'g'), 10) INTO v_send FROM app_users u JOIN employees em ON em.id = u.employee_id WHERE u.id = public.current_app_user_id();
      END IF;
      IF coalesce(length(v_send), 0) <> 10 THEN RAISE EXCEPTION 'Test mode sends texts to your own cell, and there isn''t one on your employee record. Add it there first.'; END IF;
    ELSE v_send := v_to; END IF;
  END IF;
  INSERT INTO doc_sends (kind, ref_id, title, customer_id, channel, to_address, sent_to, test, subject, body, with_pdf, pdf, file_name, sent_by)
  VALUES (left(coalesce(nullif(btrim(p_kind), ''), 'other'), 40), p_ref, left(p_title, 200), v_cust, p_channel, v_to, v_send, v_test IS NOT NULL,
          left(btrim(coalesce(p_subject, '')), 300), left(coalesce(p_body, ''), 20000), coalesce(p_with_pdf, false),
          CASE WHEN nullif(p_pdf_b64, '') IS NOT NULL THEN decode(p_pdf_b64, 'base64') END, left(coalesce(p_file_name, 'document.pdf'), 120), public.current_app_user_id())
  RETURNING * INTO r;
  RETURN jsonb_build_object('id', r.id, 'token', r.token, 'send_to', r.sent_to, 'test', r.test, 'customer_id', r.customer_id);
END $$;


-- Settings page (owners): read and change test mode
CREATE OR REPLACE FUNCTION public.send_test_get()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE
    (SELECT jsonb_build_object('email', nullif(btrim(send_test_to), ''), 'phone', nullif(btrim(send_test_phone), '')) FROM company_settings ORDER BY id LIMIT 1) END
$f$;
CREATE OR REPLACE FUNCTION public.send_test_set(p_email text, p_phone text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
DECLARE v_mail text := lower(nullif(btrim(coalesce(p_email, '')), '')); v_ph text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can change test mode'; END IF;
  IF v_mail IS NOT NULL AND v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN RAISE EXCEPTION 'That email address doesn''t look right: %', p_email; END IF;
  IF v_ph <> '' AND length(v_ph) <> 10 THEN RAISE EXCEPTION 'That phone number doesn''t look right: %', p_phone; END IF;
  UPDATE company_settings SET send_test_to = v_mail, send_test_phone = nullif(v_ph, '') WHERE id = (SELECT min(id) FROM company_settings);
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('company_settings', (SELECT id FROM company_settings ORDER BY id LIMIT 1), 'update', public.current_app_user_id(), jsonb_build_object('send_test_to', v_mail, 'send_test_phone', nullif(v_ph, '')));
  RETURN public.send_test_get();
END $f$;
REVOKE EXECUTE ON FUNCTION public.send_test_get(), public.send_test_set(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_test_get(), public.send_test_set(text, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

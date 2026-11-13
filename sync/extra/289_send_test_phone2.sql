-- Test mode: a second test text number (Carlo, Nov 13, 2026: "I have 2 numbers, I want to try it on both at the same time").
-- company_settings.send_test_phone2 (the column is added in 012). The On my way text goes to both numbers in test mode (286, Edge Function on-way-text).
-- The number itself is only in the database, never in this repository.
CREATE OR REPLACE FUNCTION public.send_test_phone2_set(p_phone text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_ph text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can change test mode'; END IF;
  IF v_ph <> '' AND length(v_ph) <> 10 THEN RAISE EXCEPTION 'That phone number doesn''t look right: %', p_phone; END IF;
  UPDATE company_settings SET send_test_phone2 = nullif(v_ph, '') WHERE id = (SELECT min(id) FROM company_settings);
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('company_settings', (SELECT id FROM company_settings ORDER BY id LIMIT 1), 'update', public.current_app_user_id(), jsonb_build_object('send_test_phone2', nullif(v_ph, '')));
  RETURN public.send_test_get();
END $f$;
REVOKE EXECUTE ON FUNCTION public.send_test_phone2_set(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_test_phone2_set(text) TO authenticated;
NOTIFY pgrst, 'reload schema';

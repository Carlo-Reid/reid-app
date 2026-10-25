-- Each person's print book (the categories ticked on the Print book page, and its options) is saved with their login,
-- so it follows them to any computer or tablet. Safe to run more than once.
ALTER TABLE public.app_users ADD COLUMN IF NOT EXISTS print_book jsonb;

CREATE OR REPLACE FUNCTION public.my_print_book()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT print_book FROM app_users WHERE id = public.current_app_user_id()
$f$;

CREATE OR REPLACE FUNCTION public.set_my_print_book(p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF public.current_app_user_id() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  IF p IS NOT NULL AND (jsonb_typeof(p) <> 'object' OR length(p::text) > 20000) THEN RAISE EXCEPTION 'That print book is too big'; END IF;
  UPDATE app_users SET print_book = p WHERE id = public.current_app_user_id();
END $f$;

REVOKE EXECUTE ON FUNCTION public.my_print_book(), public.set_my_print_book(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_print_book(), public.set_my_print_book(jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';

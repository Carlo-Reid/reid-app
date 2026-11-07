-- Book a call → Reid → Maintenance → Maintenance 1–4: the maintenance we offer, to pick which ones this visit is for
-- (Maintenance 2 = two of them, and so on). Owners and dispatch can change the list. Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.maint_options (id bigserial PRIMARY KEY, name text NOT NULL UNIQUE, sort int NOT NULL DEFAULT 0, set_by text);
ALTER TABLE public.maint_options ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.maint_options FROM PUBLIC, anon, authenticated;
INSERT INTO public.maint_options (name, sort)
SELECT x.name, x.n FROM (VALUES ('Furnace Cleaning', 1), ('Air Conditioner Cleaning', 2), ('Heat Pump Cleaning', 3), ('Ductless Mini-Split Cleaning', 4),
  ('Boiler Cleaning', 5), ('Water Heater Flush', 6), ('Humidifier Service', 7), ('HRV / ERV Cleaning', 8), ('Fireplace Cleaning', 9)) x(name, n)
WHERE NOT EXISTS (SELECT 1 FROM public.maint_options);
CREATE OR REPLACE FUNCTION public.maint_options_get() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(name ORDER BY sort, id) FROM maint_options), '[]'::jsonb) END $f$;
CREATE OR REPLACE FUNCTION public.maint_options_set(p_names text[]) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i int := 0; n text;
BEGIN
  IF NOT (public.current_staff_role() = 'owner' OR public.has_permission('calls.dispatch')) THEN RAISE EXCEPTION 'Only owners and dispatch can change this list'; END IF;
  DELETE FROM maint_options;
  FOREACH n IN ARRAY coalesce(p_names, '{}') LOOP
    IF nullif(btrim(n), '') IS NOT NULL THEN i := i + 1; INSERT INTO maint_options (name, sort, set_by) VALUES (left(btrim(n), 80), i, auth.jwt() ->> 'email') ON CONFLICT (name) DO NOTHING; END IF;
  END LOOP;
END $function$;
REVOKE EXECUTE ON FUNCTION public.maint_options_get(), public.maint_options_set(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.maint_options_get(), public.maint_options_set(text[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

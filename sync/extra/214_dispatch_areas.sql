-- Dispatch areas: the 8 (or however many) areas places are coloured by, which postal areas (first 3 characters) are in each,
-- and their colours. One row; edited on the Dispatch areas page. Staff read it; owners, office and dispatchers change it.
CREATE TABLE IF NOT EXISTS public.dispatch_area_config (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1), areas jsonb NOT NULL, updated_by text, updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.dispatch_area_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.dispatch_area_config FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.dispatch_areas_get() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS NULL THEN RETURN NULL; END IF;
  RETURN (SELECT jsonb_build_object('areas', areas, 'by', updated_by, 'at', updated_at) FROM public.dispatch_area_config WHERE id = 1);
END $function$;

CREATE OR REPLACE FUNCTION public.dispatch_areas_set(p_areas jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF coalesce(public.current_staff_role(), '') NOT IN ('owner', 'office', 'admin', 'dispatcher') THEN RAISE EXCEPTION 'Only owners and the office can change the dispatch areas'; END IF;
  IF jsonb_typeof(p_areas) IS DISTINCT FROM 'array' OR jsonb_array_length(p_areas) < 1 THEN RAISE EXCEPTION 'There has to be at least one area'; END IF;
  INSERT INTO public.dispatch_area_config (id, areas, updated_by, updated_at) VALUES (1, p_areas, auth.jwt() ->> 'email', now())
  ON CONFLICT (id) DO UPDATE SET areas = EXCLUDED.areas, updated_by = EXCLUDED.updated_by, updated_at = now();
END $function$;
REVOKE EXECUTE ON FUNCTION public.dispatch_areas_get(), public.dispatch_areas_set(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dispatch_areas_get(), public.dispatch_areas_set(jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';

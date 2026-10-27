-- 99zzzZb: price book updates live for everyone. Also runs every night from sync/extra/042_pb_live.sql. Safe to run more than once.
-- Price book live: any change to items, their categories or the category list bumps one signal row.
-- Every open price book screen listens for it and reloads, so a move (Equipment -> Parts, etc.) shows right away for everyone.
-- One bump per statement (not per row), so a bulk change of 8,000 items is still one signal.
CREATE TABLE IF NOT EXISTS public.pb_live (id int PRIMARY KEY DEFAULT 1 CHECK (id = 1), n bigint NOT NULL DEFAULT 0, changed_at timestamptz NOT NULL DEFAULT now(), what text);
INSERT INTO public.pb_live (id) VALUES (1) ON CONFLICT DO NOTHING;
ALTER TABLE public.pb_live ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS staff_read ON public.pb_live;
CREATE POLICY staff_read ON public.pb_live FOR SELECT TO authenticated USING ((SELECT public.current_staff_role()) IS NOT NULL);
REVOKE ALL ON public.pb_live FROM anon; GRANT SELECT ON public.pb_live TO authenticated;

CREATE OR REPLACE FUNCTION public._pb_live_bump() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  UPDATE public.pb_live SET n = n + 1, changed_at = now(), what = TG_TABLE_NAME WHERE id = 1;
  RETURN NULL;
END $function$;
REVOKE EXECUTE ON FUNCTION public._pb_live_bump() FROM PUBLIC, anon, authenticated;

DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['pricebook_items', 'pricebook_item_categories', 'pricebook_categories'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('DROP TRIGGER IF EXISTS pb_live_bump ON public.%I', t);
      EXECUTE format('CREATE TRIGGER pb_live_bump AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION public._pb_live_bump()', t);
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'pb_live') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.pb_live;
  END IF;
END $$;
NOTIFY pgrst, 'reload schema';

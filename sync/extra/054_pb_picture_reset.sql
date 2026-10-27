-- Price book item page: put an item's picture back.
--   * Undo the last change: every change to an item's own picture or own boxes / logos keeps the version before it
--     (the last 10), and pb_item_pic_undo puts the last one back.
--   * Reset: the original picture from the Equipment pictures page for its series, with the shared boxes
--     (its own boxes and logos taken off).
CREATE TABLE IF NOT EXISTS public.pb_pic_history (
  id bigserial PRIMARY KEY, item_id bigint NOT NULL, kind text NOT NULL CHECK (kind IN ('picture', 'boxes')),
  existed boolean NOT NULL,                     -- false = there was none (undo takes it off again)
  thumb bytea, photo bytea, source_path text, callouts jsonb, layout jsonb,
  saved_at timestamptz NOT NULL DEFAULT now(), saved_by bigint);
CREATE INDEX IF NOT EXISTS pb_pic_history_item ON public.pb_pic_history (item_id, id DESC);
ALTER TABLE public.pb_pic_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pb_pic_history FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._pb_pic_keep() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE it bigint;
BEGIN
  IF TG_OP = 'DELETE' THEN it := OLD.item_id; ELSE it := NEW.item_id; END IF;
  IF current_setting('app.pb_pic_undo', true) = '1' THEN IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END IF;
  IF TG_OP = 'INSERT' AND TG_TABLE_NAME = 'pricebook_pictures' AND EXISTS (SELECT 1 FROM pricebook_pictures WHERE item_id = it) THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' AND TG_TABLE_NAME = 'pb_item_boxes' AND EXISTS (SELECT 1 FROM pb_item_boxes WHERE item_id = it) THEN RETURN NEW; END IF;
  IF TG_TABLE_NAME = 'pricebook_pictures' THEN
    IF TG_OP = 'UPDATE' AND OLD.thumb IS NOT DISTINCT FROM NEW.thumb AND OLD.photo IS NOT DISTINCT FROM NEW.photo THEN RETURN NEW; END IF;
    INSERT INTO pb_pic_history (item_id, kind, existed, thumb, photo, source_path, saved_by)
    VALUES (it, 'picture', TG_OP <> 'INSERT', CASE WHEN TG_OP <> 'INSERT' THEN OLD.thumb END, CASE WHEN TG_OP <> 'INSERT' THEN OLD.photo END,
            CASE WHEN TG_OP <> 'INSERT' THEN OLD.source_path END, public.current_app_user_id());
  ELSE
    IF TG_OP = 'UPDATE' AND OLD.callouts IS NOT DISTINCT FROM NEW.callouts AND OLD.layout IS NOT DISTINCT FROM NEW.layout THEN RETURN NEW; END IF;
    INSERT INTO pb_pic_history (item_id, kind, existed, callouts, layout, saved_by)
    VALUES (it, 'boxes', TG_OP <> 'INSERT', CASE WHEN TG_OP <> 'INSERT' THEN OLD.callouts END, CASE WHEN TG_OP <> 'INSERT' THEN OLD.layout END, public.current_app_user_id());
  END IF;
  DELETE FROM pb_pic_history WHERE item_id = it AND id NOT IN (SELECT id FROM pb_pic_history WHERE item_id = it ORDER BY id DESC LIMIT 10);
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pb_pic_keep ON public.pricebook_pictures;
CREATE TRIGGER pb_pic_keep BEFORE INSERT OR UPDATE OR DELETE ON public.pricebook_pictures FOR EACH ROW EXECUTE FUNCTION public._pb_pic_keep();
DROP TRIGGER IF EXISTS pb_pic_keep ON public.pb_item_boxes;
CREATE TRIGGER pb_pic_keep BEFORE INSERT OR UPDATE OR DELETE ON public.pb_item_boxes FOR EACH ROW EXECUTE FUNCTION public._pb_pic_keep();

-- the picture page's picture for this item (the one picked for it, else the series that fits its name best)
CREATE OR REPLACE FUNCTION public._pb_lib_for(p_item bigint) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(
    (SELECT l.id FROM pricebook_pictures pp JOIN picture_library l ON pp.source_path = 'library:' || l.series WHERE pp.item_id = p_item),
    (SELECT h.l FROM (SELECT l.id AS l, h.id FROM pb_pic_history h JOIN picture_library l ON h.source_path = 'library:' || l.series
                      WHERE h.item_id = p_item AND h.kind = 'picture' ORDER BY h.id DESC LIMIT 1) h),
    (SELECT l.id FROM picture_library l WHERE p_item IN (SELECT public._picture_models(l.series)) ORDER BY length(l.series) DESC LIMIT 1))
$$;
REVOKE EXECUTE ON FUNCTION public._pb_lib_for(bigint) FROM PUBLIC, anon, authenticated;

-- what can be done: { undo: how many changes can be undone, last: when, lib: the picture page's series (for Reset), own: own boxes? }
CREATE OR REPLACE FUNCTION public.pb_item_pic_state(p_item bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE jsonb_build_object(
    'undo', (SELECT count(*) FROM pb_pic_history WHERE item_id = p_item),
    'last', (SELECT max(saved_at) FROM pb_pic_history WHERE item_id = p_item),
    'lib', (SELECT series FROM picture_library WHERE id = public._pb_lib_for(p_item)),
    'on_lib', EXISTS (SELECT 1 FROM pricebook_pictures pp JOIN picture_library l ON pp.source_path = 'library:' || l.series AND pp.thumb = l.image WHERE pp.item_id = p_item),
    'own', EXISTS (SELECT 1 FROM pb_item_boxes WHERE item_id = p_item)) END
$$;

CREATE OR REPLACE FUNCTION public.pb_item_pic_undo(p_item bigint)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE h pb_pic_history; t timestamptz; kinds text := '';
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  SELECT saved_at INTO t FROM pb_pic_history WHERE item_id = p_item ORDER BY id DESC LIMIT 1;
  IF t IS NULL THEN RAISE EXCEPTION 'There is nothing to undo on this picture'; END IF;
  PERFORM set_config('app.pb_pic_undo', '1', true);
  FOR h IN SELECT * FROM pb_pic_history WHERE item_id = p_item AND saved_at = t ORDER BY id DESC LOOP
  kinds := CASE WHEN kinds = '' OR kinds = h.kind THEN h.kind ELSE 'both' END;
  IF h.kind = 'picture' THEN
    IF h.existed THEN
      INSERT INTO pricebook_pictures (item_id, thumb, photo, source_path, updated_at) VALUES (p_item, h.thumb, h.photo, h.source_path, now())
      ON CONFLICT (item_id) DO UPDATE SET thumb = EXCLUDED.thumb, photo = EXCLUDED.photo, source_path = EXCLUDED.source_path, updated_at = now();
    ELSE DELETE FROM pricebook_pictures WHERE item_id = p_item; END IF;
  ELSE
    IF h.existed THEN
      INSERT INTO pb_item_boxes (item_id, callouts, layout, updated_by) VALUES (p_item, coalesce(h.callouts, '[]'), coalesce(h.layout, '{}'), public.current_app_user_id())
      ON CONFLICT (item_id) DO UPDATE SET callouts = EXCLUDED.callouts, layout = EXCLUDED.layout, updated_at = now(), updated_by = EXCLUDED.updated_by;
    ELSE DELETE FROM pb_item_boxes WHERE item_id = p_item; END IF;
  END IF;
  DELETE FROM pb_pic_history WHERE id = h.id;
  END LOOP;
  PERFORM set_config('app.pb_pic_undo', '', true);
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pricebook_items', p_item, 'update', public.current_app_user_id(), jsonb_build_object('change', 'picture: last change undone (' || kinds || ')'));
  RETURN kinds;
END $$;

CREATE OR REPLACE FUNCTION public.pb_item_pic_reset(p_item bigint)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE lib bigint := public._pb_lib_for(p_item); s text;
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pricebook_items WHERE id = p_item) THEN RAISE EXCEPTION 'Item not found'; END IF;
  DELETE FROM pb_item_boxes WHERE item_id = p_item;    -- (kept in the history, so Undo brings them back)
  IF lib IS NOT NULL THEN
    SELECT series INTO s FROM picture_library WHERE id = lib;
    INSERT INTO pricebook_pictures (item_id, thumb, photo, source_path, updated_at)
    SELECT p_item, l.image, l.image, 'library:' || l.series, now() FROM picture_library l WHERE l.id = lib
    ON CONFLICT (item_id) DO UPDATE SET thumb = EXCLUDED.thumb, photo = EXCLUDED.photo, source_path = EXCLUDED.source_path, updated_at = now();
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pricebook_items', p_item, 'update', public.current_app_user_id(), jsonb_build_object('change', 'picture reset' || coalesce(' to ' || s, ' (boxes only)')));
  RETURN coalesce(s, '');
END $$;
REVOKE EXECUTE ON FUNCTION public.pb_item_pic_state(bigint), public.pb_item_pic_undo(bigint), public.pb_item_pic_reset(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_item_pic_state(bigint), public.pb_item_pic_undo(bigint), public.pb_item_pic_reset(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- (the first version kept a wrong "there was none" step on a Reset; those few test rows are cleared)
DELETE FROM public.pb_pic_history WHERE saved_at < '2026-10-27T23:45:00+00';

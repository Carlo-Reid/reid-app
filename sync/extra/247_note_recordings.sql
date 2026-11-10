-- Call recordings on Podium call notes (Carlo, Nov 10): Podium lets him download a call's recording by hand; the app keeps the
-- file with the note, so it can be played from the customer page and stays ours. Files live in the private storage bucket
-- call-recordings (path notes/<note id>/…); this table says which file belongs to which note. Office people and owners only.
-- Taking a recording off only hides it (removed_at); the file is kept. Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.note_recordings (id bigserial PRIMARY KEY, note_id bigint NOT NULL, path text NOT NULL UNIQUE, file_name text, bytes bigint, mime text,
  added_by bigint, added_at timestamptz NOT NULL DEFAULT now(), removed_at timestamptz, removed_by bigint);
CREATE INDEX IF NOT EXISTS note_recordings_note ON public.note_recordings (note_id) WHERE removed_at IS NULL;
ALTER TABLE public.note_recordings ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public._rec_ok() RETURNS boolean
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(public.current_staff_role() IN ('owner', 'admin', 'office', 'dispatcher', 'accounting'), false) $f$;

DO $do$ BEGIN
  INSERT INTO storage.buckets (id, name, public, file_size_limit) VALUES ('call-recordings', 'call-recordings', false, 104857600) ON CONFLICT (id) DO NOTHING;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'call-recordings bucket: %', SQLERRM; END $do$;
DO $do$ BEGIN
  DROP POLICY IF EXISTS call_rec_read ON storage.objects;
  CREATE POLICY call_rec_read ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'call-recordings' AND (SELECT public._rec_ok()));
  DROP POLICY IF EXISTS call_rec_add ON storage.objects;
  CREATE POLICY call_rec_add ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'call-recordings' AND name LIKE 'notes/%' AND (SELECT public._rec_ok()));
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'call-recordings policies: %', SQLERRM; END $do$;

-- the recordings on these notes
CREATE OR REPLACE FUNCTION public.note_recordings_for(p_notes bigint[]) RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._rec_ok() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'note_id', r.note_id, 'path', r.path, 'name', r.file_name, 'bytes', r.bytes,
      'at', r.added_at, 'by', (SELECT initcap(split_part(u.login_email, '@', 1)) FROM app_users u WHERE u.id = r.added_by)) ORDER BY r.added_at)
    FROM note_recordings r WHERE r.note_id = ANY (p_notes) AND r.removed_at IS NULL), '[]'::jsonb) END $f$;

-- after the file is uploaded: tie it to the note
CREATE OR REPLACE FUNCTION public.note_recording_add(p_note bigint, p_path text, p_name text, p_bytes bigint, p_mime text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint;
BEGIN
  IF NOT public._rec_ok() THEN RAISE EXCEPTION 'Only office people and owners can add a recording'; END IF;
  IF NOT EXISTS (SELECT 1 FROM notes WHERE id = p_note) THEN RAISE EXCEPTION 'That note is gone'; END IF;
  IF p_path IS NULL OR p_path NOT LIKE 'notes/' || p_note || '/%' THEN RAISE EXCEPTION 'The file is not in the right place'; END IF;
  INSERT INTO note_recordings (note_id, path, file_name, bytes, mime, added_by) VALUES (p_note, p_path, left(p_name, 200), p_bytes, left(p_mime, 80), public.current_app_user_id())
    ON CONFLICT (path) DO UPDATE SET removed_at = NULL, removed_by = NULL RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id);
END $f$;

-- take a recording off its note (the file itself is kept)
CREATE OR REPLACE FUNCTION public.note_recording_remove(p_id bigint) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._rec_ok() THEN RAISE EXCEPTION 'Only office people and owners can do this'; END IF;
  UPDATE note_recordings SET removed_at = now(), removed_by = public.current_app_user_id() WHERE id = p_id AND removed_at IS NULL;
  RETURN jsonb_build_object('removed', FOUND);
END $f$;

REVOKE EXECUTE ON FUNCTION public._rec_ok(), public.note_recordings_for(bigint[]), public.note_recording_add(bigint, text, text, bigint, text), public.note_recording_remove(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._rec_ok(), public.note_recordings_for(bigint[]), public.note_recording_add(bigint, text, text, bigint, text), public.note_recording_remove(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

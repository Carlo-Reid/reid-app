-- A sale that was split up into other sales (e.g. a furnace + heat pump combo later sold as two proposals):
-- owners take the combo off the sales (and its commission off the lists). The proposal itself stays; it's only marked.
-- Undo puts it back. Nothing in ServiceTitan changes, and the nightly copy leaves the mark alone.
CREATE OR REPLACE FUNCTION public.est_split_remove(p_id bigint, p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e estimates;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Owners only'; END IF;
  SELECT * INTO e FROM estimates WHERE id = p_id FOR UPDATE; IF e.id IS NULL THEN RAISE EXCEPTION 'That proposal no longer exists'; END IF;
  IF e.status <> 'accepted' THEN RAISE EXCEPTION 'This proposal isn''t sold'; END IF;
  IF e.cancelled_at IS NOT NULL THEN RAISE EXCEPTION 'This sale is already taken off'; END IF;
  UPDATE estimates SET cancelled_at = now(), cancelled_by_user_id = public.current_app_user_id(),
         lost_note = coalesce(nullif(btrim(p_note), ''), 'Split up into other sales'), updated_at = now() WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('estimates', p_id, 'update', public.current_app_user_id(), jsonb_build_object('cancelled_at', NULL, 'lost_note', e.lost_note),
          jsonb_build_object('split_up', true, 'note', coalesce(nullif(btrim(p_note), ''), 'Split up into other sales')));
END $$;
REVOKE EXECUTE ON FUNCTION public.est_split_remove(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_split_remove(bigint, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.est_split_restore(p_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e estimates;
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Owners only'; END IF;
  SELECT * INTO e FROM estimates WHERE id = p_id FOR UPDATE; IF e.id IS NULL THEN RAISE EXCEPTION 'That proposal no longer exists'; END IF;
  IF e.cancelled_at IS NULL THEN RAISE EXCEPTION 'This sale isn''t taken off'; END IF;
  UPDATE estimates SET cancelled_at = NULL, cancelled_by_user_id = NULL, updated_at = now() WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('estimates', p_id, 'update', public.current_app_user_id(), jsonb_build_object('cancelled_at', e.cancelled_at), jsonb_build_object('split_up', false));
END $$;
REVOKE EXECUTE ON FUNCTION public.est_split_restore(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_split_restore(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

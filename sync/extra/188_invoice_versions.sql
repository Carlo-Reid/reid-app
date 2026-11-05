-- =====================================================================
-- An invoice edited in the app: its ServiceTitan original beside what it is now, for the Original / Edited / Side by side tabs.
-- original = ServiceTitan's invoice before it was edited here; current = the invoice now; st_now = ServiceTitan's latest.
-- Null for an invoice that wasn't edited here. Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.inv_versions(p_invoice bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE (
    SELECT jsonb_build_object('original', v.original, 'current', public._inv_st_snap(i.id), 'st_now', v.st_now, 'changed_at', v.st_changed_at,
             'edited_at', i.app_edited_at, 'edited_by', public._staff_name(i.app_edited_by))
    FROM invoices i JOIN invoice_st_versions v ON v.invoice_id = i.id WHERE i.id = p_invoice) END $f$;
REVOKE EXECUTE ON FUNCTION public.inv_versions(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inv_versions(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

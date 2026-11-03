-- Receivables: the homeowner behind an invoice billed to someone else (York UPG, a warranty or credit account…):
-- the customer at the address (or on the job) when it isn't the one billed
CREATE OR REPLACE FUNCTION public.invoice_homeowners(p_ids bigint[]) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '{}'::jsonb ELSE coalesce((SELECT jsonb_object_agg(x.id, jsonb_build_object('id', x.hid, 'name', c.display_name, 'number', c.customer_number))
    FROM (SELECT i.id, coalesce(nullif(l.customer_id, i.customer_id), nullif(j.customer_id, i.customer_id)) AS hid
          FROM invoices i LEFT JOIN locations l ON l.id = i.location_id LEFT JOIN jobs j ON j.id = i.job_id WHERE i.id = ANY (p_ids[1:3000])) x
    JOIN customers c ON c.id = x.hid), '{}') END $f$;
REVOKE EXECUTE ON FUNCTION public.invoice_homeowners(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invoice_homeowners(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

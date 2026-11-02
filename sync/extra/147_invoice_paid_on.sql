-- The day each invoice was paid (its last payment), for "Paid Oct 12, 2026" on Receivables
CREATE OR REPLACE FUNCTION public.invoice_paid_on(p_ids bigint[]) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT (public.has_permission('invoices.adjust') OR public.current_staff_role() IN ('owner', 'admin', 'accounting', 'office')) THEN '{}'::jsonb ELSE
    coalesce((SELECT jsonb_object_agg(invoice_id, d) FROM (
      SELECT pa.invoice_id, max(coalesce(p.received_on, pa.applied_at::date)) AS d
      FROM payment_applications pa JOIN payments p ON p.id = pa.payment_id
      WHERE pa.invoice_id = ANY (p_ids[1:2000]) AND pa.amount > 0 GROUP BY pa.invoice_id) x), '{}') END $f$;
REVOKE EXECUTE ON FUNCTION public.invoice_paid_on(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invoice_paid_on(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

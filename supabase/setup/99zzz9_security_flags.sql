-- =====================================================================
-- Security page: which customers have a security account, for the badges in the EFT customer search and panel.
--   monitoring = they have invoices in the "Security Monitoring" department
--   security   = they've had any security work (Security departments, or a security job type)
-- Also when their last security invoice was, and their PAP list. Owners only. Safe to run more than once.
-- =====================================================================
CREATE INDEX IF NOT EXISTS invoices_customer_bu_idx ON public.invoices (customer_id, business_unit_id);

CREATE OR REPLACE FUNCTION public.pap_security_flags(p_ids bigint[])
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH ids AS (SELECT DISTINCT unnest(p_ids[1:200]) AS id),
  bu AS (SELECT id, name ILIKE '%monitor%' AS mon FROM business_units WHERE name ILIKE '%secur%'),
  inv AS (SELECT i.customer_id, bool_or(bu.mon) AS mon, max(i.invoice_date) AS last, max(i.invoice_date) FILTER (WHERE bu.mon) AS last_mon
          FROM invoices i JOIN bu ON bu.id = i.business_unit_id
          WHERE i.customer_id IN (SELECT id FROM ids) AND i.status NOT IN ('void', 'draft') GROUP BY i.customer_id),
  jb AS (SELECT DISTINCT j.customer_id FROM jobs j JOIN job_types t ON t.id = j.job_type_id
         WHERE j.customer_id IN (SELECT id FROM ids) AND (t.job_class = 'security' OR t.name ILIKE '%secur%' OR t.name ILIKE '%alarm%'))
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE
    coalesce(jsonb_object_agg(c.id, jsonb_build_object(
      'monitoring', coalesce(inv.mon, false), 'security', inv.customer_id IS NOT NULL OR jb.customer_id IS NOT NULL,
      'last', inv.last, 'last_monitoring', inv.last_mon, 'pap_list', c.pap_list)), '{}') END
  FROM ids JOIN customers c ON c.id = ids.id
  LEFT JOIN inv ON inv.customer_id = c.id LEFT JOIN jb ON jb.customer_id = c.id
$$;
REVOKE EXECUTE ON FUNCTION public.pap_security_flags(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_security_flags(bigint[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

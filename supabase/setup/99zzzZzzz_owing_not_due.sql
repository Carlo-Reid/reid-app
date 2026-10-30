-- Receivables: an invoice for work that isn't done yet (the job still has a booked visit) isn't due yet.
-- open_balances gives: job_done, done_on (when the work was finished), booked_for (the booked visit's day) and booked_on (when it was booked).
DROP FUNCTION IF EXISTS public.open_balances(text, text);
CREATE OR REPLACE FUNCTION public.open_balances(p_show text DEFAULT 'todo', p_kind text DEFAULT 'all')
RETURNS TABLE (invoice_id bigint, invoice_number text, invoice_date date, total numeric, balance numeric, status text,
               customer_id bigint, customer_name text, street text, city text, job_type text,
               plan_sale boolean, monthly_plan boolean, not_owed_reason text, checked_at timestamptz, checked_by text, marked_by text,
               over_total boolean, paid numeric, job_class text, job_partner_id bigint, job_partner text,
               job_done boolean, done_on date, booked_for date, booked_on date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT i.id, i.invoice_number, i.invoice_date, i.total, i.balance_due, i.status,
         c.id, c.display_name, l.street, l.city, t.name,
         EXISTS (SELECT 1 FROM invoice_lines il WHERE il.invoice_id = i.id AND il.description ILIKE '%membership%'),
         EXISTS (SELECT 1 FROM memberships m WHERE m.customer_id = c.id AND m.status = 'active' AND m.billing_frequency = 'monthly'),
         i.not_owed_reason, i.owing_checked_at, public._staff_name(i.owing_checked_by), public._staff_name(i.not_owed_by),
         i.balance_due > i.total + 0.01, i.amount_paid, t.job_class, j.partner_id, (SELECT p.name FROM partners p WHERE p.id = j.partner_id),
         -- the work isn't done yet (an open visit on the job): not due until it is
         NOT (j.id IS NOT NULL AND j.completed_at IS NULL AND coalesce(j.status, '') NOT IN ('completed', 'cancelled') AND nv.scheduled_date IS NOT NULL),
         j.completed_at::date, nv.scheduled_date, nv.created_at::date
  FROM invoices i
  JOIN customers c ON c.id = i.customer_id
  LEFT JOIN locations l ON l.id = i.location_id
  LEFT JOIN jobs j ON j.id = i.job_id
  LEFT JOIN job_types t ON t.id = j.job_type_id
  LEFT JOIN LATERAL (SELECT v.scheduled_date, v.created_at FROM visits v WHERE v.job_id = j.id AND coalesce(v.status, '') NOT IN ('completed', 'cancelled')
                     ORDER BY v.scheduled_date LIMIT 1) nv ON true
  WHERE (public.has_permission('invoices.adjust') OR public.current_staff_role() IN ('owner', 'admin', 'accounting'))
    AND i.balance_due > 0.004 AND i.status NOT IN ('void', 'draft')
    AND NOT public._inv_store_pays(i.look, i.branding_partner_id, i.bill_to_partner_id, j.partner_id)
    AND CASE coalesce(p_show, 'todo')
          WHEN 'todo'     THEN i.not_owed_reason IS NULL AND i.owing_checked_at IS NULL
          WHEN 'checked'  THEN i.not_owed_reason IS NULL AND i.owing_checked_at IS NOT NULL
          WHEN 'not_owed' THEN i.not_owed_reason IS NOT NULL
          ELSE true END
    AND CASE coalesce(p_kind, 'all')
          WHEN 'plan'    THEN EXISTS (SELECT 1 FROM invoice_lines il WHERE il.invoice_id = i.id AND il.description ILIKE '%membership%')
          WHEN 'over'    THEN i.balance_due > i.total + 0.01
          WHEN 'monthly' THEN EXISTS (SELECT 1 FROM memberships m WHERE m.customer_id = c.id AND m.status = 'active' AND m.billing_frequency = 'monthly')
          ELSE true END
  ORDER BY i.invoice_date DESC, i.id DESC
  LIMIT 2000
$$;
REVOKE EXECUTE ON FUNCTION public.open_balances(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.open_balances(text, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

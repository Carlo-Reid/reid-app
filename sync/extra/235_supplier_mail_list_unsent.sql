-- Auto update: the supplier mail list shows only papers that haven't been sent to a supplier's list.
-- A paper sent and then saved into Supplier invoices had come back onto the main list with its Send button
-- (pressing it looked like nothing was sent). Sent ones no longer use up the list's 80 places either. (Carlo, Nov 9)
-- Safe to run more than once.
CREATE OR REPLACE FUNCTION public.supplier_mail_list(p_limit integer DEFAULT 80)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN NOT public._can_approve_costs() THEN NULL ELSE jsonb_build_object(
    'last_check', (SELECT value FROM supplier_mail_state WHERE key = 'last_check'),
    'last_error', (SELECT value FROM supplier_mail_state WHERE key = 'last_error'),
    'waiting', (SELECT count(*) FROM supplier_mail WHERE status = 'new'),
    'needs_look', (SELECT count(*) FROM supplier_mail WHERE status IN ('unread', 'needs_supplier', 'error') AND sent_at IS NULL AND received_at > now() - interval '30 days'),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'received', m.received_at, 'from', coalesce(nullif(m.from_name, ''), m.from_addr), 'from_addr', m.from_addr,
               'subject', m.subject, 'file', m.file_name, 'mime', m.mime, 'size', m.size, 'status', m.status, 'result', m.result, 'scanned', m.ocr_text IS NOT NULL,
               'supplier', coalesce(m.supplier, public._supplier_from_text(concat_ws(' ', m.subject, m.file_name, m.body_text)), public._supplier_from_text(left(m.ocr_text, 700)),
                                    public._supplier_from_text(concat_ws(' ', m.from_addr, m.from_name))),
               'done_at', m.done_at, 'done_by', public._emp_name((SELECT u.employee_id FROM app_users u WHERE u.id = m.done_by)))
             ORDER BY m.received_at DESC NULLS LAST, m.id DESC), '[]')
             FROM (SELECT * FROM supplier_mail WHERE sent_at IS NULL ORDER BY (status = 'new') DESC, received_at DESC NULLS LAST, id DESC LIMIT least(coalesce(p_limit, 80), 500)) m)) END
$function$;
NOTIFY pgrst, 'reload schema';

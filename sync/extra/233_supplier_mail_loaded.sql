-- A document sent to a supplier's list and then loaded into their Supplier invoices (saved in the reader) leaves the
-- Sent lists and can't be loaded again (Carlo, Nov 9). Safe to run more than once.
ALTER TABLE public.supplier_mail ADD COLUMN IF NOT EXISTS loaded_at timestamptz;
ALTER TABLE public.supplier_mail ADD COLUMN IF NOT EXISTS loaded_by text;

-- the sent ones (one supplier, or all), newest first
CREATE OR REPLACE FUNCTION public.supplier_mail_sent(p_supplier bigint DEFAULT NULL, p_limit integer DEFAULT 200) RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._can_see_costs() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(x ORDER BY x ->> 'sent_at' DESC) FROM (
    SELECT jsonb_build_object('id', m.id, 'file', m.file_name, 'subject', m.subject, 'received', m.received_at, 'from', coalesce(nullif(m.from_name, ''), m.from_addr),
             'from_addr', m.from_addr, 'status', m.status, 'result', m.result, 'supplier_id', m.sent_supplier_id, 'supplier', s.name,
             'sent_at', m.sent_at, 'sent_by', m.sent_by,
             'pos', (SELECT coalesce(jsonb_agg(p.po_number ORDER BY p.po_number), '[]') FROM supplier_mail_pos x JOIN purchase_orders p ON p.id = x.purchase_order_id WHERE x.mail_id = m.id)) AS x
    FROM supplier_mail m LEFT JOIN suppliers s ON s.id = m.sent_supplier_id
    WHERE m.sent_at IS NOT NULL AND m.loaded_at IS NULL AND (p_supplier IS NULL OR m.sent_supplier_id = p_supplier)
    ORDER BY m.sent_at DESC LIMIT least(greatest(coalesce(p_limit, 200), 1), 1000)) q), '[]'::jsonb) END $f$;


CREATE OR REPLACE FUNCTION public.supplier_mail_loaded(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  UPDATE supplier_mail SET loaded_at = now(), loaded_by = auth.jwt() ->> 'email' WHERE id = p_id AND loaded_at IS NULL;
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_mail_loaded(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_mail_loaded(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

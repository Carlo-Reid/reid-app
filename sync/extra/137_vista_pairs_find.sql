-- Tank and labour invoices: each pair carries a "find" text with everything it can be found by
-- (both invoice #s, job #s, the jobs' POs, the supplier invoices on those POs and the PO printed on them, names, address, supplier, amounts)
DO $do$
DECLARE src text := pg_get_functiondef('public.vista_tank_pairs(bigint, text)'::regprocedure);
BEGIN
  IF src LIKE '%''find''%' THEN RETURN; END IF;
  src := replace(src, $a$'job_number', j.job_number,$a$, $a$'job_number', j.job_number,
    'find', lower(concat_ws(' ', tk.invoice_number, lb.invoice_number, j.job_number, (SELECT job_number FROM jobs WHERE id = lb.job_id), c.display_name,
      (SELECT display_name FROM customers WHERE id = l.customer_id), l.street, l.city, (SELECT name FROM suppliers WHERE id = r.supplier_id), tk.total, lb.total,
      (SELECT string_agg(po.po_number || ' ' || coalesce(po.supplier_reference, '') || ' ' || coalesce((SELECT name FROM suppliers WHERE id = po.supplier_id), ''), ' ') FROM purchase_orders po WHERE po.job_id IN (tk.job_id, lb.job_id)),
      (SELECT string_agg(si.supplier_invoice_number || ' ' || coalesce(si.po_text, '') || ' ' || coalesce(si.total::text, ''), ' ')
         FROM purchase_orders po JOIN supplier_invoices si ON si.purchase_order_id = po.id OR (si.po_text IS NOT NULL AND si.po_text LIKE '%' || split_part(po.po_number, '-', 1) || '%')
         WHERE po.job_id IN (tk.job_id, lb.job_id)))),$a$);
  IF src NOT LIKE '%''find''%' THEN RAISE EXCEPTION 'vista_tank_pairs: anchor not found'; END IF;
  EXECUTE src;
END $do$;
NOTIFY pgrst, 'reload schema';

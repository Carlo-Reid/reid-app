-- POs page: what is attached to each PO (Carlo, Nov 12, 2026: "on the POs page add any document it is attached to and make it clickable").
-- s = the supplier's papers on the PO (invoice, credit, packing slip; a credit's Credit Memo number), i = our customer invoices (the PO's job, or tied to one of those papers),
-- c = the customer of the PO's job, f = how many emailed papers are on the PO. People who see costs.
CREATE OR REPLACE FUNCTION public.po_attachments(p_ids bigint[]) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  WITH ok AS (SELECT public._can_see_costs() AS ok),
       po AS (SELECT p.id, p.job_id FROM purchase_orders p, ok WHERE ok.ok AND p.id = ANY (p_ids[1:3000])),
       sx AS (SELECT po.id AS po_id, si.id AS sid FROM po JOIN supplier_invoices si ON si.purchase_order_id = po.id
              UNION SELECT po.id, m.supplier_invoice_id FROM po JOIN supplier_credit_memos m ON m.purchase_order_id = po.id),
       s AS (SELECT sx.po_id, jsonb_agg(jsonb_build_object('id', si.id, 'n', si.supplier_invoice_number, 'sup', btrim(sp.name), 'sup_id', si.supplier_id, 'tot', si.total, 'd', si.invoice_date,
                      'k', CASE WHEN coalesce(si.read_notes, '') ILIKE '%packing slip%' THEN 'slip' WHEN si.doc_type IN ('credit', 'return') OR si.total < 0 THEN 'credit' ELSE 'invoice' END,
                      'memo', (SELECT m.memo_number FROM supplier_credit_memos m WHERE m.supplier_invoice_id = si.id LIMIT 1)) ORDER BY si.invoice_date, si.id) AS v
             FROM sx JOIN supplier_invoices si ON si.id = sx.sid JOIN suppliers sp ON sp.id = si.supplier_id GROUP BY sx.po_id),
       ix AS (SELECT po.id AS po_id, ci.id AS iid FROM po JOIN invoices ci ON ci.job_id = po.job_id
              UNION SELECT sx.po_id, k.invoice_id FROM sx JOIN supplier_invoice_customer_links k ON k.supplier_invoice_id = sx.sid),
       i AS (SELECT ix.po_id, jsonb_agg(jsonb_build_object('id', ci.id, 'n', ci.invoice_number) ORDER BY ci.id) AS v FROM ix JOIN invoices ci ON ci.id = ix.iid AND ci.status::text <> 'void' GROUP BY ix.po_id),
       f AS (SELECT po.id AS po_id, count(*) AS n FROM po JOIN supplier_mail_pos x ON x.purchase_order_id = po.id GROUP BY po.id)
  SELECT coalesce(jsonb_object_agg(po.id, jsonb_strip_nulls(jsonb_build_object('s', s.v, 'i', i.v, 'f', f.n,
           'c', (SELECT jsonb_build_object('id', c.id, 'name', c.display_name) FROM jobs j JOIN customers c ON c.id = j.customer_id WHERE j.id = po.job_id)))), '{}')
  FROM po LEFT JOIN s ON s.po_id = po.id LEFT JOIN i ON i.po_id = po.id LEFT JOIN f ON f.po_id = po.id $f$;
REVOKE EXECUTE ON FUNCTION public.po_attachments(bigint[]) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.po_attachments(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Every document connected to a job, for the customer page's lines (Job history, and Proposals through the proposal's job): Carlo, Nov 11, 2026.
-- Same shape as invoice_attachments (183): s = supplier invoices (through the job's invoices, or through a PO made for the job; people who see costs),
-- d = the job's documents, p = how many photos, r = partner remittances that paid the job's invoices (owners), and po = the job's purchase orders (people who see costs).
-- Nov 12, 2026: also e = the job's proposals, for the Calls page's Attached column (Carlo: "attach all documents and pictures").
CREATE OR REPLACE FUNCTION public.job_attachments(p_ids bigint[]) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  WITH jb AS (SELECT j.id FROM jobs j WHERE j.id = ANY (p_ids[1:1000])),
       cost AS (SELECT public._can_see_costs() AS ok), own AS (SELECT public._bank_owner() AS ok)
  SELECT coalesce(jsonb_object_agg(jb.id, jsonb_strip_nulls(jsonb_build_object(
    'job', jb.id,
    's', CASE WHEN (SELECT ok FROM cost) THEN (SELECT jsonb_agg(x.o ORDER BY x.d, x.id) FROM (
              SELECT DISTINCT ON (s.id) s.id, s.invoice_date AS d, jsonb_build_object('id', s.id, 'n', s.supplier_invoice_number, 'sup', btrim(sp.name), 'sup_id', s.supplier_id, 't', s.doc_type, 'tot', s.total, 'd', s.invoice_date) AS o
              FROM supplier_invoices s JOIN suppliers sp ON sp.id = s.supplier_id
              WHERE s.id IN (SELECT k.supplier_invoice_id FROM supplier_invoice_customer_links k JOIN invoices i ON i.id = k.invoice_id WHERE i.job_id = jb.id)
                 OR s.purchase_order_id IN (SELECT po.id FROM purchase_orders po WHERE po.job_id = jb.id)) x) END,
    'po', CASE WHEN (SELECT ok FROM cost) THEN (SELECT jsonb_agg(jsonb_build_object('id', po.id, 'n', po.po_number, 'sup', btrim(sp.name)) ORDER BY po.id)
              FROM purchase_orders po LEFT JOIN suppliers sp ON sp.id = po.supplier_id WHERE po.job_id = jb.id AND coalesce(po.status::text, '') NOT ILIKE 'cancel%') END,
    'd', (SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', regexp_replace(a.file_name, '^.*/', ''), 'key', a.storage_key, 'mime', a.mime_type) ORDER BY a.taken_at, a.id)
          FROM attachments a WHERE a.entity_type = 'job' AND a.entity_id = jb.id AND a.storage_key IS NOT NULL AND coalesce(a.mime_type, '') NOT LIKE 'image/%' AND coalesce(a.mime_type, '') <> 'application/smil'),
    'p', (SELECT nullif(count(*), 0) FROM attachments a WHERE a.entity_type = 'job' AND a.entity_id = jb.id AND a.storage_key IS NOT NULL AND a.mime_type LIKE 'image/%'),
    'e', (SELECT jsonb_agg(jsonb_build_object('id', e.id, 'n', e.estimate_number) ORDER BY e.id) FROM estimates e WHERE e.job_id = jb.id),
    'r', CASE WHEN (SELECT ok FROM own) THEN (SELECT jsonb_agg(DISTINCT jsonb_build_object('id', r.id, 'ref', r.reference, 'd', r.pay_date, 'who', coalesce(r.payer, ''), 'pdf', r.pdf IS NOT NULL))
              FROM partner_remit_doc_lines l JOIN partner_remit_docs r ON r.id = l.doc_id JOIN invoices i ON i.id = l.invoice_id WHERE i.job_id = jb.id) END))), '{}')
  FROM jb $f$;
REVOKE EXECUTE ON FUNCTION public.job_attachments(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.job_attachments(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

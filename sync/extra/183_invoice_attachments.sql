-- Every attachment an invoice has, for buttons on Receivables and on the invoice:
--   s = supplier invoices attached to it (people who can see costs), d = the job's documents (PDFs, videos), p = how many photos the job has,
--   r = the partner remittance(s) that paid it (owners only). One call for a page of invoices.
CREATE INDEX IF NOT EXISTS attachments_entity ON public.attachments (entity_type, entity_id);
CREATE OR REPLACE FUNCTION public.invoice_attachments(p_ids bigint[]) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  WITH iv AS (SELECT i.id, i.job_id FROM invoices i WHERE i.id = ANY (p_ids[1:1000])),
       cost AS (SELECT public._can_see_costs() AS ok), own AS (SELECT public._bank_owner() AS ok)
  SELECT coalesce(jsonb_object_agg(iv.id, jsonb_strip_nulls(jsonb_build_object(
    'job', iv.job_id,
    's', CASE WHEN (SELECT ok FROM cost) THEN (SELECT jsonb_agg(jsonb_build_object('id', s.id, 'n', s.supplier_invoice_number, 'sup', btrim(sp.name), 'sup_id', s.supplier_id, 't', s.doc_type, 'tot', s.total, 'd', s.invoice_date) ORDER BY s.invoice_date, s.id)
              FROM supplier_invoice_customer_links k JOIN supplier_invoices s ON s.id = k.supplier_invoice_id JOIN suppliers sp ON sp.id = s.supplier_id WHERE k.invoice_id = iv.id) END,
    'd', (SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', regexp_replace(a.file_name, '^.*/', ''), 'key', a.storage_key, 'mime', a.mime_type) ORDER BY a.taken_at, a.id)
          FROM attachments a WHERE iv.job_id IS NOT NULL AND a.entity_type = 'job' AND a.entity_id = iv.job_id AND a.storage_key IS NOT NULL AND coalesce(a.mime_type, '') NOT LIKE 'image/%' AND coalesce(a.mime_type, '') <> 'application/smil'),
    'p', (SELECT nullif(count(*), 0) FROM attachments a WHERE iv.job_id IS NOT NULL AND a.entity_type = 'job' AND a.entity_id = iv.job_id AND a.storage_key IS NOT NULL AND a.mime_type LIKE 'image/%'),
    'r', CASE WHEN (SELECT ok FROM own) THEN (SELECT jsonb_agg(DISTINCT jsonb_build_object('id', r.id, 'ref', r.reference, 'd', r.pay_date, 'who', coalesce(r.payer, ''), 'pdf', r.pdf IS NOT NULL))
              FROM partner_remit_doc_lines l JOIN partner_remit_docs r ON r.id = l.doc_id WHERE l.invoice_id = iv.id) END))), '{}')
  FROM iv $f$;
REVOKE EXECUTE ON FUNCTION public.invoice_attachments(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invoice_attachments(bigint[]) TO authenticated;
-- a job's photos (the Photos button)
CREATE OR REPLACE FUNCTION public.job_photo_list(p_job bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', regexp_replace(a.file_name, '^.*/', ''), 'key', a.storage_key, 'thumb', a.thumb_key, 'mime', a.mime_type, 'at', a.taken_at) ORDER BY a.taken_at, a.id), '[]')
  FROM attachments a WHERE a.entity_type = 'job' AND a.entity_id = p_job AND a.storage_key IS NOT NULL AND a.mime_type LIKE 'image/%' $f$;
REVOKE EXECUTE ON FUNCTION public.job_photo_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.job_photo_list(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

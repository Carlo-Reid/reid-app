-- Auto update: "Send to <supplier> list" moves a document off the main supplier mail list onto that supplier's
-- "Sent to suppliers" list (and the supplier's page shows it). Also finds the PO a document is for, even when the
-- scan misread one digit (a highlighter made 106607062 read as 406607062). Safe to run more than once.
ALTER TABLE public.supplier_mail ADD COLUMN IF NOT EXISTS sent_supplier_id bigint;
ALTER TABLE public.supplier_mail ADD COLUMN IF NOT EXISTS sent_at timestamptz;
ALTER TABLE public.supplier_mail ADD COLUMN IF NOT EXISTS sent_by text;
CREATE INDEX IF NOT EXISTS supplier_mail_sent_idx ON public.supplier_mail (sent_supplier_id, sent_at DESC) WHERE sent_at IS NOT NULL;

CREATE OR REPLACE FUNCTION public._supplier_id_of(p_name text) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT s.id FROM suppliers s
   WHERE p_name IS NOT NULL AND btrim(p_name) <> '' AND (lower(btrim(s.name)) = lower(btrim(p_name)) OR s.name ILIKE btrim(p_name) || ' %' OR s.name ILIKE btrim(p_name) || '(%')
   ORDER BY (SELECT count(*) FROM purchase_orders p WHERE p.supplier_id = s.id) DESC LIMIT 1 $f$;
REVOKE EXECUTE ON FUNCTION public._supplier_id_of(text) FROM PUBLIC, anon, authenticated;

-- send it (or p_undo: put it back on the main list)
CREATE OR REPLACE FUNCTION public.supplier_mail_send(p_id bigint, p_supplier text, p_undo boolean DEFAULT false) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_sup bigint;
BEGIN
  IF NOT public._can_approve_costs() THEN RAISE EXCEPTION 'You need to be able to approve costs for this'; END IF;
  IF p_undo THEN UPDATE supplier_mail SET sent_supplier_id = NULL, sent_at = NULL, sent_by = NULL WHERE id = p_id; RETURN '{}'::jsonb; END IF;
  v_sup := public._supplier_id_of(p_supplier);
  IF v_sup IS NULL THEN RAISE EXCEPTION 'Pick the supplier first'; END IF;
  UPDATE supplier_mail SET supplier = btrim(p_supplier), sent_supplier_id = v_sup, sent_at = now(), sent_by = auth.jwt() ->> 'email' WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That document isn''t on the list any more'; END IF;
  RETURN jsonb_build_object('supplier_id', v_sup, 'supplier', (SELECT name FROM suppliers WHERE id = v_sup));
END $function$;

-- the sent ones (one supplier, or all), newest first
CREATE OR REPLACE FUNCTION public.supplier_mail_sent(p_supplier bigint DEFAULT NULL, p_limit integer DEFAULT 200) RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._can_see_costs() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(x ORDER BY x ->> 'sent_at' DESC) FROM (
    SELECT jsonb_build_object('id', m.id, 'file', m.file_name, 'subject', m.subject, 'received', m.received_at, 'from', coalesce(nullif(m.from_name, ''), m.from_addr),
             'from_addr', m.from_addr, 'status', m.status, 'result', m.result, 'supplier_id', m.sent_supplier_id, 'supplier', s.name,
             'sent_at', m.sent_at, 'sent_by', m.sent_by,
             'pos', (SELECT coalesce(jsonb_agg(p.po_number ORDER BY p.po_number), '[]') FROM supplier_mail_pos x JOIN purchase_orders p ON p.id = x.purchase_order_id WHERE x.mail_id = m.id)) AS x
    FROM supplier_mail m LEFT JOIN suppliers s ON s.id = m.sent_supplier_id
    WHERE m.sent_at IS NOT NULL AND (p_supplier IS NULL OR m.sent_supplier_id = p_supplier)
    ORDER BY m.sent_at DESC LIMIT least(greatest(coalesce(p_limit, 200), 1), 1000)) q), '[]'::jsonb) END $f$;

-- open a sent document (anyone who can see costs)
CREATE OR REPLACE FUNCTION public.supplier_doc_file(p_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._can_see_costs() THEN NULL ELSE
    (SELECT jsonb_build_object('name', m.file_name, 'mime', m.mime, 'b64', encode(m.data, 'base64')) FROM supplier_mail m WHERE m.id = p_id AND m.sent_at IS NOT NULL) END $f$;

-- the POs a document is probably for: a PO number printed on it, or one digit off (a misread scan), this supplier's first
CREATE OR REPLACE FUNCTION public.supplier_mail_po_guess(p_id bigint, p_text text DEFAULT NULL) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_text text; v_sup bigint; v_nums text[];
BEGIN
  IF NOT public._can_approve_costs() THEN RETURN '[]'::jsonb; END IF;
  SELECT concat_ws(' ', subject, file_name, ocr_text, p_text), public._supplier_id_of(supplier) INTO v_text, v_sup FROM supplier_mail WHERE id = p_id;
  SELECT array_agg(DISTINCT m[1]) INTO v_nums FROM regexp_matches(left(coalesce(v_text, ''), 100000), '(\d{7,12})', 'g') m;
  IF v_nums IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(g ORDER BY (g ->> 'rank')::int, g ->> 'po_number') FROM (SELECT g FROM (
    SELECT DISTINCT ON (p.id) jsonb_build_object('id', p.id, 'po_number', p.po_number, 'status', p.status, 'made', p.created_at::date,
             'supplier', s.name, 'read_as', n, 'exact', n = split_part(p.po_number, '-', 1),
             'job', j.job_number, 'customer', to_jsonb(c) ->> 'name',
             'rank', (CASE WHEN n = split_part(p.po_number, '-', 1) THEN 0 ELSE 2 END) + (CASE WHEN v_sup IS NOT NULL AND p.supplier_id = v_sup THEN 0 ELSE 1 END)) AS g
    FROM unnest(v_nums) n
    JOIN purchase_orders p ON length(split_part(p.po_number, '-', 1)) = length(n)
     AND (split_part(p.po_number, '-', 1) = n
          OR (p.created_at > now() - interval '2 years'
              AND (SELECT count(*) FROM generate_series(1, length(n)) i WHERE substr(n, i, 1) <> substr(split_part(p.po_number, '-', 1), i, 1)) = 1))
    LEFT JOIN suppliers s ON s.id = p.supplier_id
    LEFT JOIN jobs j ON j.id = p.job_id
    LEFT JOIN customers c ON c.id = j.customer_id
    WHERE coalesce(p.status, '') <> 'cancelled'
      AND (v_sup IS NULL OR p.supplier_id = v_sup OR n = split_part(p.po_number, '-', 1))
      AND NOT EXISTS (SELECT 1 FROM supplier_mail_pos x WHERE x.mail_id = p_id AND x.purchase_order_id = p.id)
    ORDER BY p.id) q0 ORDER BY (g ->> 'rank')::int, g ->> 'po_number' LIMIT 6) q), '[]'::jsonb);
END $function$;

REVOKE EXECUTE ON FUNCTION public.supplier_mail_send(bigint, text, boolean), public.supplier_mail_sent(bigint, integer), public.supplier_doc_file(bigint), public.supplier_mail_po_guess(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_mail_send(bigint, text, boolean), public.supplier_mail_sent(bigint, integer), public.supplier_doc_file(bigint), public.supplier_mail_po_guess(bigint, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

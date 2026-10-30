-- Supplier scans and emailed files tied to the POs printed on them, so a PO (and the supplier invoice matched to it) shows them.
CREATE TABLE IF NOT EXISTS public.supplier_mail_pos (
  mail_id bigint NOT NULL REFERENCES public.supplier_mail(id) ON DELETE CASCADE,
  purchase_order_id bigint NOT NULL REFERENCES public.purchase_orders(id) ON DELETE CASCADE,
  how text NOT NULL DEFAULT 'printed',          -- printed (read off the copy) or by_hand
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (mail_id, purchase_order_id));
CREATE INDEX IF NOT EXISTS supplier_mail_pos_po ON public.supplier_mail_pos (purchase_order_id);
ALTER TABLE public.supplier_mail_pos ENABLE ROW LEVEL SECURITY;   -- only through the functions below
CREATE INDEX IF NOT EXISTS purchase_orders_po_base ON public.purchase_orders (split_part(po_number, '-', 1));

-- the POs whose numbers are on a page: "116603643-001" exactly, or a bare "116776798" when that job has just one PO with this supplier
CREATE OR REPLACE FUNCTION public._mail_link_pos(p_mail bigint, p_text text, p_supplier text DEFAULT NULL)
 RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_sup bigint; v_full text[]; v_bare text[]; v_out text[];
BEGIN
  IF coalesce(p_text, '') = '' THEN RETURN '{}'; END IF;
  SELECT s.id INTO v_sup FROM suppliers s
   WHERE p_supplier IS NOT NULL AND (lower(btrim(s.name)) = lower(btrim(p_supplier)) OR s.name ILIKE btrim(p_supplier) || ' %' OR s.name ILIKE btrim(p_supplier) || '(%')
   ORDER BY (SELECT count(*) FROM purchase_orders p WHERE p.supplier_id = s.id) DESC LIMIT 1;
  SELECT array_agg(DISTINCT m[1] || '-' || m[2]) INTO v_full FROM regexp_matches(left(p_text, 100000), '(?<![\d-])(\d{6,12})\s?-\s?(\d{3})(?!\d)', 'g') m;
  SELECT array_agg(DISTINCT m[1]) INTO v_bare FROM regexp_matches(left(p_text, 100000), '(?<![\d-])(\d{7,12})(?![\d-])', 'g') m;
  INSERT INTO supplier_mail_pos (mail_id, purchase_order_id, how)
  SELECT DISTINCT p_mail, p.id, 'printed' FROM purchase_orders p
   WHERE p.po_number = ANY (coalesce(v_full, '{}')) AND (v_sup IS NULL OR p.supplier_id = v_sup)
  UNION
  SELECT p_mail, min(p.id), 'printed' FROM purchase_orders p
   WHERE v_sup IS NOT NULL AND p.supplier_id = v_sup AND coalesce(p.status, '') <> 'cancelled'
     AND (p.po_number = ANY (coalesce(v_bare, '{}')) OR split_part(p.po_number, '-', 1) = ANY (coalesce(v_bare, '{}')))
     AND NOT EXISTS (SELECT 1 FROM purchase_orders q WHERE q.po_number = ANY (coalesce(v_full, '{}')) AND split_part(q.po_number, '-', 1) = split_part(p.po_number, '-', 1))
   GROUP BY split_part(p.po_number, '-', 1) HAVING count(*) = 1
  ON CONFLICT DO NOTHING;
  SELECT array_agg(p.po_number ORDER BY p.po_number) INTO v_out FROM supplier_mail_pos x JOIN purchase_orders p ON p.id = x.purchase_order_id WHERE x.mail_id = p_mail;
  RETURN coalesce(v_out, '{}');
END $function$;
REVOKE EXECUTE ON FUNCTION public._mail_link_pos(bigint, text, text) FROM PUBLIC, anon, authenticated;

-- the app calls this after reading a file (the words of a PDF that has text inside never reach the database otherwise)
CREATE OR REPLACE FUNCTION public.supplier_mail_link_pos(p_id bigint, p_text text, p_supplier text DEFAULT NULL)
 RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public._can_approve_costs() THEN RAISE EXCEPTION 'You need to be able to approve costs for this'; END IF;
  RETURN public._mail_link_pos(p_id, coalesce(p_text, '') || ' ' || coalesce((SELECT concat_ws(' ', subject, file_name, body_text, ocr_text) FROM supplier_mail WHERE id = p_id), ''),
                               coalesce(p_supplier, (SELECT supplier FROM supplier_mail WHERE id = p_id)));
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_mail_link_pos(bigint, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_mail_link_pos(bigint, text, text) TO authenticated;

-- tie a file to a PO by hand (or untie it)
CREATE OR REPLACE FUNCTION public.supplier_mail_set_po(p_id bigint, p_po_number text, p_remove boolean DEFAULT false)
 RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_po bigint; v_out text[];
BEGIN
  IF NOT public._can_approve_costs() THEN RAISE EXCEPTION 'You need to be able to approve costs for this'; END IF;
  SELECT id INTO v_po FROM purchase_orders WHERE po_number = btrim(p_po_number) ORDER BY id DESC LIMIT 1;
  IF v_po IS NULL THEN RAISE EXCEPTION 'There''s no PO % in the app', btrim(p_po_number); END IF;
  IF p_remove THEN DELETE FROM supplier_mail_pos WHERE mail_id = p_id AND purchase_order_id = v_po;
  ELSE INSERT INTO supplier_mail_pos (mail_id, purchase_order_id, how) VALUES (p_id, v_po, 'by_hand') ON CONFLICT DO NOTHING; END IF;
  SELECT array_agg(p.po_number ORDER BY p.po_number) INTO v_out FROM supplier_mail_pos x JOIN purchase_orders p ON p.id = x.purchase_order_id WHERE x.mail_id = p_id;
  RETURN coalesce(v_out, '{}');
END $function$;
REVOKE EXECUTE ON FUNCTION public.supplier_mail_set_po(bigint, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_mail_set_po(bigint, text, boolean) TO authenticated;

-- the files on a PO (no file contents: just the list)
CREATE OR REPLACE FUNCTION public.po_files(p_po bigint)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN NOT public._can_see_costs() THEN '[]'::jsonb ELSE
    (SELECT coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'file', m.file_name, 'mime', m.mime, 'received', m.received_at, 'from', coalesce(nullif(m.from_name, ''), m.from_addr),
            'subject', m.subject, 'how', x.how) ORDER BY m.received_at DESC NULLS LAST, m.id DESC), '[]')
     FROM supplier_mail_pos x JOIN supplier_mail m ON m.id = x.mail_id WHERE x.purchase_order_id = p_po) END
$function$;
REVOKE EXECUTE ON FUNCTION public.po_files(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.po_files(bigint) TO authenticated;

-- open one of them (only a file that's on a PO, for anyone who can see costs)
CREATE OR REPLACE FUNCTION public.po_file(p_id bigint)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN NOT public._can_see_costs() THEN NULL ELSE
    (SELECT jsonb_build_object('name', m.file_name, 'mime', m.mime, 'b64', encode(m.data, 'base64')) FROM supplier_mail m
      WHERE m.id = p_id AND EXISTS (SELECT 1 FROM supplier_mail_pos x WHERE x.mail_id = m.id)) END
$function$;
REVOKE EXECUTE ON FUNCTION public.po_file(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.po_file(bigint) TO authenticated;

-- a scan's words arrive later (read on GitHub): tie it to its POs then
CREATE OR REPLACE FUNCTION public._supplier_mail_ocr_pos() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(NEW.ocr_text, '') <> '' THEN
    PERFORM public._mail_link_pos(NEW.id, concat_ws(' ', NEW.subject, NEW.file_name, NEW.body_text, NEW.ocr_text),
      coalesce(NEW.supplier, public._supplier_from_text(left(NEW.ocr_text, 700)), CASE WHEN NEW.ocr_text ~* 'master\.ca|816\s*609\s*234' THEN 'Master' END));
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN   -- tying it to a PO must never stop the scan being saved
  RAISE WARNING 'supplier_mail_ocr_pos %: %', NEW.id, SQLERRM;
  RETURN NEW;
END $function$;
DROP TRIGGER IF EXISTS supplier_mail_ocr_pos ON public.supplier_mail;
CREATE TRIGGER supplier_mail_ocr_pos AFTER INSERT OR UPDATE OF ocr_text, supplier ON public.supplier_mail FOR EACH ROW EXECUTE FUNCTION public._supplier_mail_ocr_pos();

-- the scans already read
SELECT public._mail_link_pos(m.id, concat_ws(' ', m.subject, m.file_name, m.body_text, m.ocr_text),
       coalesce(m.supplier, public._supplier_from_text(left(m.ocr_text, 700)), CASE WHEN m.ocr_text ~* 'master\.ca|816\s*609\s*234' THEN 'Master' END))
  FROM supplier_mail m WHERE coalesce(m.ocr_text, '') <> '' OR coalesce(m.body_text, '') <> '';

NOTIFY pgrst, 'reload schema';

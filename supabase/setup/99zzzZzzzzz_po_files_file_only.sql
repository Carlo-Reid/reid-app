-- Tie a supplier file to POs only by what's on the file itself (and the email's subject), not the email's body:
-- a body can list other orders (e.g. a covering note), which tied one Boone file to 16 POs.
CREATE OR REPLACE FUNCTION public.supplier_mail_link_pos(p_id bigint, p_text text, p_supplier text DEFAULT NULL)
 RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public._can_approve_costs() THEN RAISE EXCEPTION 'You need to be able to approve costs for this'; END IF;
  RETURN public._mail_link_pos(p_id, coalesce(p_text, '') || ' ' || coalesce((SELECT concat_ws(' ', subject, file_name, ocr_text) FROM supplier_mail WHERE id = p_id), ''),
                               coalesce(p_supplier, (SELECT supplier FROM supplier_mail WHERE id = p_id)));
END $function$;

CREATE OR REPLACE FUNCTION public._supplier_mail_ocr_pos() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(NEW.ocr_text, '') <> '' THEN
    PERFORM public._mail_link_pos(NEW.id, concat_ws(' ', NEW.subject, NEW.file_name, NEW.ocr_text),
      coalesce(NEW.supplier, public._supplier_from_text(left(NEW.ocr_text, 700)), CASE WHEN NEW.ocr_text ~* 'master\.ca|816\s*609\s*234' THEN 'Master' END));
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'supplier_mail_ocr_pos %: %', NEW.id, SQLERRM;
  RETURN NEW;
END $function$;

-- redo the ones tied so far (files whose words the app reads in the browser are tied again when read)
DELETE FROM public.supplier_mail_pos WHERE how = 'printed';
SELECT public._mail_link_pos(m.id, concat_ws(' ', m.subject, m.file_name, m.ocr_text),
       coalesce(m.supplier, public._supplier_from_text(left(m.ocr_text, 700)), CASE WHEN m.ocr_text ~* 'master\.ca|816\s*609\s*234' THEN 'Master' END))
  FROM supplier_mail m WHERE coalesce(m.ocr_text, '') <> '';
NOTIFY pgrst, 'reload schema';

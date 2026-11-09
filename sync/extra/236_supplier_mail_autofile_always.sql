-- Auto update: a paper that's found and matched and needs nothing more goes to its supplier's list the moment that's
-- true, whoever or whatever did the last step (the app reading it, a PO attached by hand, or the scan reader tying the
-- PO in the background). Before, it only happened while someone had the Auto update page open. (Carlo, Nov 9)
--   done = read with nothing left to do (status imported / nothing), supplier known, a PO attached, not put back by hand.
-- Safe to run more than once.
CREATE OR REPLACE FUNCTION public._supplier_mail_file_if_done(p_id bigint) RETURNS void
 LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE supplier_mail m SET sent_supplier_id = public._supplier_id_of(m.supplier), sent_at = now(), sent_by = 'the app'
   WHERE m.id = p_id AND m.data IS NOT NULL AND m.sent_at IS NULL AND NOT m.keep_on_list AND m.status IN ('imported', 'nothing')
     AND public._supplier_id_of(m.supplier) IS NOT NULL
     AND EXISTS (SELECT 1 FROM supplier_mail_pos x WHERE x.mail_id = m.id) $f$;
REVOKE EXECUTE ON FUNCTION public._supplier_mail_file_if_done(bigint) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._supplier_mail_file_trg() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF TG_TABLE_NAME = 'supplier_mail_pos' THEN PERFORM public._supplier_mail_file_if_done(NEW.mail_id);
  ELSE PERFORM public._supplier_mail_file_if_done(NEW.id); END IF;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN   -- filing it must never stop the reading or the PO being saved
  RAISE WARNING 'supplier_mail_file_trg: %', SQLERRM;
  RETURN NULL;
END $f$;
REVOKE EXECUTE ON FUNCTION public._supplier_mail_file_trg() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS supplier_mail_pos_file ON public.supplier_mail_pos;
CREATE TRIGGER supplier_mail_pos_file AFTER INSERT ON public.supplier_mail_pos FOR EACH ROW EXECUTE FUNCTION public._supplier_mail_file_trg();
DROP TRIGGER IF EXISTS supplier_mail_done_file ON public.supplier_mail;
CREATE TRIGGER supplier_mail_done_file AFTER UPDATE OF status, supplier ON public.supplier_mail FOR EACH ROW
  WHEN (NEW.sent_at IS NULL AND NEW.status IN ('imported', 'nothing')) EXECUTE FUNCTION public._supplier_mail_file_trg();

-- the ones that are done right now
SELECT public._supplier_mail_file_if_done(m.id) FROM supplier_mail m
 WHERE m.sent_at IS NULL AND m.status IN ('imported', 'nothing') AND EXISTS (SELECT 1 FROM supplier_mail_pos x WHERE x.mail_id = m.id);

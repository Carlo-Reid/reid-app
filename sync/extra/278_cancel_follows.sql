-- Nov 13 (Carlo: "when a job or invoice is cancelled it should also cancel the P.O. or Credit Memo").
-- An invoice that is cancelled (made void, or removed) cancels the tank P.O. made from it and its Credit Order that is still waiting.
-- A job that is cancelled (or deleted) cancels every P.O. of the job that is not received yet, and its Credit Orders that are still waiting.
-- A P.O. that is already received or billed is left as it is (the parts are here); a job note says so.
CREATE OR REPLACE FUNCTION public._cancel_po_quiet(p_id bigint, p_why text, p_note boolean) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE o purchase_orders; v_me bigint := public.current_app_user_id();
BEGIN
  SELECT * INTO o FROM purchase_orders WHERE id = p_id;
  IF o.id IS NULL OR o.status::text = 'cancelled' THEN RETURN false; END IF;
  IF o.status::text NOT IN ('draft', 'approved', 'sent') THEN
    IF p_note AND o.job_id IS NOT NULL AND EXISTS (SELECT 1 FROM jobs WHERE id = o.job_id) THEN
      INSERT INTO notes (entity_type, entity_id, body, author_user_id, source)
      VALUES ('job', o.job_id, 'PO ' || o.po_number || ' was not cancelled, because it is already received (' || p_why || '). Cancel it by hand if it should be.', v_me, 'po');
    END IF;
    RETURN false;
  END IF;
  UPDATE purchase_orders SET status = 'cancelled',
         notes = concat_ws(E'\n', nullif(notes, ''), 'Cancelled by the app on ' || to_char(now() AT TIME ZONE 'America/Toronto', 'Mon FMDD, YYYY') || ': ' || p_why || '.')
  WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('purchase_orders', p_id, 'update', v_me, to_jsonb(o), jsonb_build_object('status', 'cancelled', 'why', p_why));
  IF p_note AND o.job_id IS NOT NULL AND EXISTS (SELECT 1 FROM jobs WHERE id = o.job_id) THEN
    INSERT INTO notes (entity_type, entity_id, body, author_user_id, source)
    VALUES ('job', o.job_id, 'PO ' || o.po_number || ' cancelled: ' || p_why || '.', v_me, 'po');
  END IF;
  RETURN true;
END $function$;
REVOKE EXECUTE ON FUNCTION public._cancel_po_quiet(bigint, text, boolean) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._cancel_tank_orders(p_invoice bigint, p_job bigint, p_why text, p_note boolean) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE t tank_orders; n int := 0; v_me bigint := public.current_app_user_id();
BEGIN
  FOR t IN SELECT * FROM tank_orders WHERE (p_invoice IS NOT NULL AND invoice_id = p_invoice) OR (p_invoice IS NULL AND p_job IS NOT NULL AND job_id = p_job) LOOP
    IF t.purchase_order_id IS NOT NULL AND public._cancel_po_quiet(t.purchase_order_id, p_why, p_note) THEN n := n + 1; END IF;
    IF t.credit_number IS NOT NULL AND t.credit_status = 'waiting' THEN
      UPDATE tank_orders SET credit_status = 'cancelled' WHERE id = t.id;
      INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
      VALUES ('tank_orders', t.id, 'update', v_me, jsonb_build_object('credit_order', t.credit_number, 'step', 'cancel', 'why', p_why));
      IF p_note AND t.job_id IS NOT NULL AND EXISTS (SELECT 1 FROM jobs WHERE id = t.job_id) THEN
        INSERT INTO notes (entity_type, entity_id, body, author_user_id, source)
        VALUES ('job', t.job_id, 'Credit Order ' || t.credit_number || ' cancelled: ' || p_why || '.', v_me, 'po');
      END IF;
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $function$;
REVOKE EXECUTE ON FUNCTION public._cancel_tank_orders(bigint, bigint, text, boolean) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._trg_invoice_cancel_follow() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.store_copy_of IS NULL THEN PERFORM public._cancel_tank_orders(OLD.id, OLD.job_id, 'invoice ' || coalesce(OLD.invoice_number, OLD.id::text) || ' was cancelled and removed', true); END IF;
    RETURN OLD;
  END IF;
  IF NEW.store_copy_of IS NULL THEN PERFORM public._cancel_tank_orders(NEW.id, NEW.job_id, 'invoice ' || coalesce(NEW.invoice_number, NEW.id::text) || ' was cancelled', true); END IF;
  RETURN NEW;
END $function$;
DROP TRIGGER IF EXISTS trg_invoice_cancel_follow ON public.invoices;
CREATE TRIGGER trg_invoice_cancel_follow AFTER UPDATE OF status ON public.invoices
  FOR EACH ROW WHEN (NEW.status::text = 'void' AND OLD.status::text IS DISTINCT FROM 'void') EXECUTE FUNCTION public._trg_invoice_cancel_follow();
DROP TRIGGER IF EXISTS trg_invoice_delete_follow ON public.invoices;
CREATE TRIGGER trg_invoice_delete_follow BEFORE DELETE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public._trg_invoice_cancel_follow();

CREATE OR REPLACE FUNCTION public._trg_job_cancel_follow() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE j jobs; del boolean := TG_OP = 'DELETE'; v_why text; p record;
BEGIN
  IF del THEN j := OLD; ELSE j := NEW; END IF;
  v_why := 'job ' || coalesce(j.job_number, j.id::text) || CASE WHEN del THEN ' was deleted' ELSE ' was cancelled' END;
  FOR p IN SELECT id FROM purchase_orders WHERE job_id = j.id LOOP PERFORM public._cancel_po_quiet(p.id, v_why, NOT del); END LOOP;
  PERFORM public._cancel_tank_orders(NULL, j.id, v_why, NOT del);
  IF del THEN RETURN OLD; END IF;
  RETURN NEW;
END $function$;
DROP TRIGGER IF EXISTS trg_job_cancel_follow ON public.jobs;
CREATE TRIGGER trg_job_cancel_follow AFTER UPDATE OF status ON public.jobs
  FOR EACH ROW WHEN (NEW.status::text = 'cancelled' AND OLD.status::text IS DISTINCT FROM 'cancelled') EXECUTE FUNCTION public._trg_job_cancel_follow();
DROP TRIGGER IF EXISTS trg_job_delete_follow ON public.jobs;
CREATE TRIGGER trg_job_delete_follow BEFORE DELETE ON public.jobs
  FOR EACH ROW EXECUTE FUNCTION public._trg_job_cancel_follow();

-- the ones already cancelled before this rule: tank orders whose invoice is void or gone, or whose job is cancelled or gone
DO $do$
DECLARE t record;
BEGIN
  FOR t IN SELECT o.id, o.invoice_id, o.job_id, i.id AS inv, i.status::text AS inv_status, j.id AS job, j.status::text AS job_status
           FROM tank_orders o LEFT JOIN invoices i ON i.id = o.invoice_id LEFT JOIN jobs j ON j.id = o.job_id
           WHERE (o.credit_status = 'waiting' OR EXISTS (SELECT 1 FROM purchase_orders p WHERE p.id = o.purchase_order_id AND p.status::text IN ('draft', 'approved', 'sent')))
             AND (i.id IS NULL OR i.status::text = 'void' OR j.id IS NULL OR j.status::text = 'cancelled') LOOP
    PERFORM public._cancel_tank_orders(t.invoice_id, t.job_id,
      CASE WHEN t.job IS NULL THEN 'its job was deleted' WHEN t.job_status = 'cancelled' THEN 'its job was cancelled' WHEN t.inv IS NULL THEN 'its invoice was cancelled and removed' ELSE 'its invoice was cancelled' END, t.job IS NOT NULL);
  END LOOP;
END $do$;

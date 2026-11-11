-- Supplier credits: a credit that comes back from a supplier gets a Credit Memo (not a P.O.), and a Credit Order that is
-- waiting (a Vista tank, 259) is answered by itself when the supplier's credit paper comes in. (Carlo, Nov 11, 2026)
-- One row = one supplier credit paper: CM-<id>, the supplier, the credit paper, the P.O. it is against (when known),
-- the credit order it answered (when one), and the P.O. that had been made from the credit by mistake (replaced_po_id).
CREATE TABLE IF NOT EXISTS public.supplier_credit_memos (
  id bigserial PRIMARY KEY, memo_number text,
  supplier_id bigint, supplier_invoice_id bigint NOT NULL UNIQUE, purchase_order_id bigint, tank_order_id bigint,
  amount numeric, how text NOT NULL DEFAULT 'hand',   -- hand | auto (a credit order matched) | fixed (a P.O. had been made from the credit)
  replaced_po_id bigint, note text, created_by bigint, created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.supplier_credit_memos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.supplier_credit_memos FROM PUBLIC, anon, authenticated;

-- makes the memo for a credit paper (once). A P.O. that was made from this same credit is taken off it and cancelled (kept, not deleted).
CREATE OR REPLACE FUNCTION public._credit_memo_make(p_invoice bigint, p_how text, p_tank bigint DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i supplier_invoices; v_id bigint; v_old bigint; v_po bigint; v_me bigint := public.current_app_user_id(); v_how text := p_how;
BEGIN
  SELECT * INTO i FROM supplier_invoices WHERE id = p_invoice; IF i.id IS NULL THEN RETURN NULL; END IF;
  SELECT id INTO v_id FROM supplier_credit_memos WHERE supplier_invoice_id = i.id;
  IF v_id IS NOT NULL THEN
    IF p_tank IS NOT NULL THEN UPDATE supplier_credit_memos SET tank_order_id = coalesce(tank_order_id, p_tank) WHERE id = v_id; END IF;
    RETURN v_id;
  END IF;
  -- a P.O. made from this credit itself (Supplier invoices, "make a PO from it"): not a real order
  SELECT po.id INTO v_old FROM purchase_orders po WHERE po.id = i.purchase_order_id AND po.description ILIKE '%from credit%' AND po.job_id IS NULL
    AND NOT EXISTS (SELECT 1 FROM supplier_invoices x WHERE x.purchase_order_id = po.id AND x.id <> i.id);
  IF v_old IS NOT NULL THEN
    UPDATE supplier_invoices SET purchase_order_id = NULL, updated_at = now() WHERE id = i.id;
    UPDATE purchase_orders SET status = 'cancelled', notes = btrim(coalesce(notes, '') || E'\nCancelled: it was made from a supplier credit. The credit has a Credit Memo now.') WHERE id = v_old;
    i.purchase_order_id := NULL; IF v_how = 'hand' THEN v_how := 'fixed'; END IF;
  END IF;
  SELECT id INTO v_id FROM supplier_credit_memos WHERE supplier_invoice_id = i.id;   -- taking the P.O. off can match a waiting credit order, which makes the memo
  IF v_id IS NOT NULL THEN UPDATE supplier_credit_memos SET replaced_po_id = coalesce(replaced_po_id, v_old) WHERE id = v_id; RETURN v_id; END IF;
  v_po := coalesce((SELECT purchase_order_id FROM tank_orders WHERE id = p_tank), public._sinv_po(i));
  INSERT INTO supplier_credit_memos (supplier_id, supplier_invoice_id, purchase_order_id, tank_order_id, amount, how, replaced_po_id, created_by)
  VALUES (i.supplier_id, i.id, v_po, p_tank, abs(coalesce(nullif(i.total, 0), i.subtotal, 0)), v_how, v_old, v_me) RETURNING id INTO v_id;
  UPDATE supplier_credit_memos SET memo_number = 'CM-' || v_id WHERE id = v_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_credit_memos', v_id, 'insert', v_me, jsonb_build_object('credit', i.supplier_invoice_number, 'how', v_how, 'replaced_po', v_old, 'credit_order', p_tank));
  RETURN v_id;
END $function$;

-- a supplier's credit paper came in: if a Credit Order is waiting for it (same supplier, the tank's P.O. number on the paper), answer it
CREATE OR REPLACE FUNCTION public._credit_order_auto(p_invoice bigint) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i supplier_invoices; t tank_orders; v_text text; v_po bigint;
BEGIN
  SELECT * INTO i FROM supplier_invoices WHERE id = p_invoice;
  IF i.id IS NULL OR NOT (i.doc_type IN ('credit', 'return') OR coalesce(i.total, 0) < 0) THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM supplier_credit_memos WHERE supplier_invoice_id = i.id AND (tank_order_id IS NOT NULL OR how = 'auto')) THEN RETURN NULL; END IF;   -- matched once already (an Undo stays undone)
  v_text := coalesce(i.po_text, '') || ' ' || coalesce(i.original_order, '') || ' ' || coalesce(i.job_name, '');
  v_po := public._sinv_po(i);
  SELECT x.* INTO t FROM tank_orders x JOIN purchase_orders po ON po.id = x.purchase_order_id
  WHERE x.credit_status = 'waiting' AND (x.supplier_id = i.supplier_id OR x.supplier_id IS NULL)
    AND (po.id = v_po OR strpos(v_text, po.po_number) > 0)
  ORDER BY (strpos(v_text, po.po_number) > 0) DESC, x.id LIMIT 1;
  IF t.id IS NULL THEN RETURN NULL; END IF;
  UPDATE tank_orders SET credit_status = 'received', credit_ref = i.supplier_invoice_number,
    credit_amount = coalesce(nullif(abs(coalesce(i.subtotal, 0)), 0), nullif(abs(coalesce(i.total, 0)), 0), credit_amount), credit_received_at = now(), credit_received_by = NULL WHERE id = t.id;
  PERFORM public._credit_memo_make(i.id, 'auto', t.id);
  INSERT INTO notes (entity_type, entity_id, body, source)
  SELECT 'job', t.job_id, 'Credit Order ' || t.credit_number || ': the credit came back (' || coalesce(i.supplier_invoice_number, 'credit') || '). The app matched it by itself.', 'po' WHERE t.job_id IS NOT NULL;
  INSERT INTO audit_log (table_name, row_id, action, new_values) VALUES ('tank_orders', t.id, 'update', jsonb_build_object('credit_order', t.credit_number, 'step', 'received by itself', 'credit', i.supplier_invoice_number));
  RETURN t.id;
END $function$;

CREATE OR REPLACE FUNCTION public._trg_credit_order_auto() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NEW.doc_type IN ('credit', 'return') OR coalesce(NEW.total, 0) < 0 THEN
    BEGIN PERFORM public._credit_order_auto(NEW.id); EXCEPTION WHEN others THEN NULL; END;   -- never stops a supplier paper from saving
  END IF;
  RETURN NULL;
END $function$;
DROP TRIGGER IF EXISTS trg_credit_order_auto ON public.supplier_invoices;
CREATE TRIGGER trg_credit_order_auto AFTER INSERT OR UPDATE OF doc_type, po_text, original_order, job_name, purchase_order_id, total, supplier_id
  ON public.supplier_invoices FOR EACH ROW EXECUTE FUNCTION public._trg_credit_order_auto();

-- a new credit order also looks at the credits that are already in (the paper can come first)
CREATE OR REPLACE FUNCTION public._trg_tank_order_look() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE r record;
BEGIN
  IF NEW.credit_status = 'waiting' AND NEW.purchase_order_id IS NOT NULL THEN
    BEGIN
      FOR r IN SELECT i.id FROM supplier_invoices i JOIN purchase_orders po ON po.id = NEW.purchase_order_id
               WHERE i.doc_type IN ('credit', 'return') AND i.supplier_id = NEW.supplier_id AND i.created_at > now() - interval '120 days'
                 AND NOT EXISTS (SELECT 1 FROM supplier_credit_memos m WHERE m.supplier_invoice_id = i.id)
                 AND strpos(coalesce(i.po_text, '') || ' ' || coalesce(i.original_order, '') || ' ' || coalesce(i.job_name, ''), po.po_number) > 0 LIMIT 1 LOOP
        PERFORM public._credit_order_auto(r.id);
      END LOOP;
    EXCEPTION WHEN others THEN NULL; END;
  END IF;
  RETURN NULL;
END $function$;
DROP TRIGGER IF EXISTS trg_tank_order_look ON public.tank_orders;
CREATE TRIGGER trg_tank_order_look AFTER UPDATE OF credit_status ON public.tank_orders FOR EACH ROW WHEN (NEW.credit_status = 'waiting' AND OLD.credit_status IS DISTINCT FROM 'waiting')
  EXECUTE FUNCTION public._trg_tank_order_look();

-- the app: the memo of a credit paper, make one, take it off
CREATE OR REPLACE FUNCTION public.credit_memo_for(p_invoice bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN NOT (public._sinv_can_edit() OR public._can_see_costs() OR public._tank_office()) THEN NULL ELSE
    (SELECT jsonb_build_object('id', m.id, 'number', m.memo_number, 'amount', m.amount, 'how', m.how, 'at', m.created_at,
        'by', (SELECT nullif(btrim(e.first_name), '') FROM app_users u LEFT JOIN employees e ON e.id = u.employee_id WHERE u.id = m.created_by),
        'po_id', m.purchase_order_id, 'po_number', po.po_number, 'replaced_po', rp.po_number,
        'credit_order', t.credit_number, 'tank_invoice', t.invoice_id)
     FROM supplier_credit_memos m LEFT JOIN purchase_orders po ON po.id = m.purchase_order_id LEFT JOIN purchase_orders rp ON rp.id = m.replaced_po_id
       LEFT JOIN tank_orders t ON t.id = m.tank_order_id WHERE m.supplier_invoice_id = p_invoice) END $function$;

CREATE OR REPLACE FUNCTION public.credit_memo_make(p_invoice bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE i supplier_invoices; v_id bigint;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  SELECT * INTO i FROM supplier_invoices WHERE id = p_invoice; IF i.id IS NULL THEN RAISE EXCEPTION 'That paper is gone'; END IF;
  IF NOT (i.doc_type IN ('credit', 'return') OR coalesce(i.total, 0) < 0) THEN RAISE EXCEPTION 'This paper is not a credit'; END IF;
  PERFORM public._credit_order_auto(i.id);   -- a waiting credit order first
  v_id := public._credit_memo_make(i.id, 'hand', NULL);
  RETURN public.credit_memo_for(i.id);
END $function$;

CREATE OR REPLACE FUNCTION public.credit_memo_remove(p_invoice bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE m supplier_credit_memos;
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  SELECT * INTO m FROM supplier_credit_memos WHERE supplier_invoice_id = p_invoice; IF m.id IS NULL THEN RETURN; END IF;
  IF m.tank_order_id IS NOT NULL THEN RAISE EXCEPTION 'This Credit Memo answered a Credit Order. Undo the Credit Order on its invoice first.'; END IF;
  DELETE FROM supplier_credit_memos WHERE id = m.id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values) VALUES ('supplier_credit_memos', m.id, 'delete', public.current_app_user_id(), to_jsonb(m));
END $function$;

-- undoing "the credit came back" on a credit order also lets go of the memo's tie to it
CREATE OR REPLACE FUNCTION public._trg_tank_order_unmemo() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN UPDATE supplier_credit_memos SET tank_order_id = NULL WHERE tank_order_id = NEW.id; RETURN NULL; END $function$;
DROP TRIGGER IF EXISTS trg_tank_order_unmemo ON public.tank_orders;
CREATE TRIGGER trg_tank_order_unmemo AFTER UPDATE OF credit_status ON public.tank_orders FOR EACH ROW WHEN (OLD.credit_status = 'received' AND NEW.credit_status IS DISTINCT FROM 'received')
  EXECUTE FUNCTION public._trg_tank_order_unmemo();

-- the past: credits that had a P.O. made from them get a Credit Memo, and that P.O. is cancelled (kept on file)
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT i.id FROM supplier_invoices i JOIN purchase_orders po ON po.id = i.purchase_order_id
           WHERE (i.doc_type IN ('credit', 'return') OR coalesce(i.total, 0) < 0) AND po.description ILIKE '%from credit%' AND po.job_id IS NULL AND po.status <> 'cancelled'
             AND NOT EXISTS (SELECT 1 FROM supplier_credit_memos m WHERE m.supplier_invoice_id = i.id) LOOP
    PERFORM public._credit_memo_make(r.id, 'fixed', NULL);
  END LOOP;
END $$;

-- the Supplier invoices list: the memo number of each credit paper (for the tag on its line)
CREATE OR REPLACE FUNCTION public.credit_memos_list(p_supplier bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT CASE WHEN NOT (public._sinv_can_edit() OR public._can_see_costs() OR public._tank_office()) THEN '{}'::jsonb ELSE
    coalesce((SELECT jsonb_object_agg(m.supplier_invoice_id::text, m.memo_number) FROM supplier_credit_memos m WHERE p_supplier IS NULL OR m.supplier_id = p_supplier), '{}'::jsonb) END $function$;
REVOKE EXECUTE ON FUNCTION public.credit_memos_list(bigint) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.credit_memos_list(bigint) TO authenticated;
-- the Credit Memos page: find and list the memos
CREATE OR REPLACE FUNCTION public.credit_memo_list(p_search text DEFAULT NULL, p_supplier bigint DEFAULT NULL, p_kind text DEFAULT 'all', p_limit int DEFAULT 300) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE q text := nullif(lower(btrim(coalesce(p_search, ''))), ''); v jsonb; n int; tot numeric;
BEGIN
  IF NOT (public._sinv_can_edit() OR public._can_see_costs() OR public._tank_office()) THEN RETURN jsonb_build_object('rows', '[]'::jsonb, 'count', 0, 'total', 0); END IF;
  WITH base AS (
    SELECT m.id, m.memo_number, m.amount, m.how, m.created_at, m.supplier_id, btrim(s.name) AS supplier, i.id AS inv, i.supplier_invoice_number AS credit, i.invoice_date,
           po.id AS po_id, po.po_number, rp.po_number AS replaced_po, t.credit_number AS credit_order, t.invoice_id AS tank_invoice
    FROM supplier_credit_memos m JOIN supplier_invoices i ON i.id = m.supplier_invoice_id LEFT JOIN suppliers s ON s.id = m.supplier_id
      LEFT JOIN purchase_orders po ON po.id = m.purchase_order_id LEFT JOIN purchase_orders rp ON rp.id = m.replaced_po_id LEFT JOIN tank_orders t ON t.id = m.tank_order_id
    WHERE (p_supplier IS NULL OR m.supplier_id = p_supplier)
      AND (coalesce(p_kind, 'all') = 'all' OR (p_kind = 'order' AND m.tank_order_id IS NOT NULL) OR (p_kind = 'fixed' AND m.replaced_po_id IS NOT NULL) OR (p_kind = 'new' AND m.how IN ('hand', 'auto')))
      AND (q IS NULL OR lower(m.memo_number) LIKE '%' || q || '%' OR lower(coalesce(i.supplier_invoice_number, '')) LIKE '%' || q || '%' OR lower(coalesce(s.name, '')) LIKE '%' || q || '%'
           OR lower(coalesce(po.po_number, '')) LIKE '%' || q || '%' OR lower(coalesce(t.credit_number, '')) LIKE '%' || q || '%' OR lower(coalesce(i.po_text, '')) LIKE '%' || q || '%'))
  SELECT (SELECT count(*) FROM base), (SELECT coalesce(sum(amount), 0) FROM base),
         coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT * FROM base ORDER BY invoice_date DESC NULLS LAST, id DESC LIMIT greatest(1, least(coalesce(p_limit, 300), 2000))) x), '[]'::jsonb)
  INTO n, tot, v;
  RETURN jsonb_build_object('rows', v, 'count', n, 'total', tot);
END $function$;
REVOKE EXECUTE ON FUNCTION public.credit_memo_list(text, bigint, text, int) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.credit_memo_list(text, bigint, text, int) TO authenticated;
REVOKE EXECUTE ON FUNCTION public._credit_memo_make(bigint, text, bigint), public._credit_order_auto(bigint), public.credit_memo_for(bigint), public.credit_memo_make(bigint), public.credit_memo_remove(bigint) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public._credit_memo_make(bigint, text, bigint), public._credit_order_auto(bigint) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.credit_memo_for(bigint), public.credit_memo_make(bigint), public.credit_memo_remove(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

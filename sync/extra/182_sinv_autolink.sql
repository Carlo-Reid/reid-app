-- Supplier invoices are attached on their own to every customer invoice on their PO's job (not void).
-- One taken off by hand is remembered and not put back. Runs with each sync, every 10 minutes after the supplier mail is read,
-- and whenever an invoice is opened (for that invoice's job).
CREATE TABLE IF NOT EXISTS public.supplier_invoice_customer_unlinks (
  supplier_invoice_id bigint NOT NULL REFERENCES public.supplier_invoices(id) ON DELETE CASCADE, invoice_id bigint NOT NULL,
  removed_by bigint, removed_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (supplier_invoice_id, invoice_id));
ALTER TABLE public.supplier_invoice_customer_unlinks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.supplier_invoice_customer_unlinks FROM PUBLIC, anon, authenticated;
ALTER TABLE public.supplier_invoice_customer_links ADD COLUMN IF NOT EXISTS auto boolean NOT NULL DEFAULT false;

-- attach: p_job limits it to one job (null = every supplier invoice); returns how many were attached
CREATE OR REPLACE FUNCTION public._sinv_autolink(p_job bigint DEFAULT NULL) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int;
BEGIN
  WITH sp AS (SELECT s.id, po.job_id FROM supplier_invoices s CROSS JOIN LATERAL (SELECT public._sinv_po(s) AS po_id) x
              JOIN purchase_orders po ON po.id = x.po_id
              WHERE po.job_id IS NOT NULL AND (p_job IS NULL OR po.job_id = p_job)
                AND (p_job IS NULL OR s.purchase_order_id = po.id OR s.po_text IS NOT NULL)),
       ins AS (INSERT INTO supplier_invoice_customer_links (supplier_invoice_id, invoice_id, linked_by, auto)
               SELECT sp.id, i.id, NULL, true FROM sp JOIN invoices i ON i.job_id = sp.job_id AND coalesce(i.status, '') <> 'void'
               WHERE NOT EXISTS (SELECT 1 FROM supplier_invoice_customer_unlinks u WHERE u.supplier_invoice_id = sp.id AND u.invoice_id = i.id)
               ON CONFLICT DO NOTHING RETURNING 1)
  SELECT count(*) INTO n FROM ins;
  RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public._sinv_autolink(bigint) FROM PUBLIC, anon, authenticated;

-- taking one off by hand is remembered; putting it back clears that
CREATE OR REPLACE FUNCTION public.sinv_cust_link(p_sinv bigint, p_invoice bigint, p_on boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._sinv_can_edit() THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  IF p_on THEN
    IF NOT EXISTS (SELECT 1 FROM invoices WHERE id = p_invoice) THEN RAISE EXCEPTION 'That invoice is gone'; END IF;
    INSERT INTO supplier_invoice_customer_links (supplier_invoice_id, invoice_id, linked_by) VALUES (p_sinv, p_invoice, public.current_app_user_id()) ON CONFLICT DO NOTHING;
    DELETE FROM supplier_invoice_customer_unlinks WHERE supplier_invoice_id = p_sinv AND invoice_id = p_invoice;
  ELSE
    DELETE FROM supplier_invoice_customer_links WHERE supplier_invoice_id = p_sinv AND invoice_id = p_invoice;
    INSERT INTO supplier_invoice_customer_unlinks (supplier_invoice_id, invoice_id, removed_by) VALUES (p_sinv, p_invoice, public.current_app_user_id())
      ON CONFLICT (supplier_invoice_id, invoice_id) DO UPDATE SET removed_by = EXCLUDED.removed_by, removed_at = now();
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('supplier_invoice_customer_links', p_sinv, CASE WHEN p_on THEN 'insert' ELSE 'delete' END, public.current_app_user_id(), jsonb_build_object('invoice', p_invoice));
END $f$;

-- an invoice's supplier invoices: attaches any new ones for its job first
CREATE OR REPLACE FUNCTION public.invoice_supplier_invoices(p_invoice bigint) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_job bigint;
BEGIN
  IF NOT public._can_see_costs() THEN RETURN NULL; END IF;
  SELECT job_id INTO v_job FROM invoices WHERE id = p_invoice;
  IF v_job IS NOT NULL THEN BEGIN PERFORM public._sinv_autolink(v_job); EXCEPTION WHEN OTHERS THEN NULL; END; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'number', s.supplier_invoice_number, 'date', s.invoice_date,
      'total', s.total, 'supplier_id', s.supplier_id, 'supplier', btrim(sp.name), 'doc_type', s.doc_type) ORDER BY s.invoice_date, s.id)
    FROM supplier_invoice_customer_links k JOIN supplier_invoices s ON s.id = k.supplier_invoice_id JOIN suppliers sp ON sp.id = s.supplier_id WHERE k.invoice_id = p_invoice), '[]');
END $f$;
REVOKE EXECUTE ON FUNCTION public.invoice_supplier_invoices(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invoice_supplier_invoices(bigint) TO authenticated;

-- every supplier invoice so far (and again with each sync)
DO $$ DECLARE n int; BEGIN n := public._sinv_autolink(NULL); RAISE NOTICE 'sinv autolink: % attached', n; END $$;
NOTIFY pgrst, 'reload schema';

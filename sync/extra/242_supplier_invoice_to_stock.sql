-- Supplier invoices: "Add to our stock" (Carlo, Nov 10, 2026). One press puts the parts on a supplier invoice into a stock place.
-- Each part is matched to our price list by the supplier's own part number (supplier_items), else by our code (sku).
-- What was added is remembered per invoice, so the same invoice can't be added twice (unless the stock move was undone).
CREATE TABLE IF NOT EXISTS public.supplier_invoice_stock (
  id bigserial PRIMARY KEY, supplier_invoice_id bigint NOT NULL REFERENCES public.supplier_invoices(id) ON DELETE CASCADE,
  line_no int NOT NULL, item_id bigint NOT NULL, quantity numeric NOT NULL, txn_id bigint, location_id bigint,
  added_at timestamptz NOT NULL DEFAULT now(), added_by bigint);
CREATE INDEX IF NOT EXISTS supplier_invoice_stock_inv ON public.supplier_invoice_stock (supplier_invoice_id);
ALTER TABLE public.supplier_invoice_stock ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.supplier_invoice_to_stock(p_id bigint, p_place bigint DEFAULT NULL, p_dry boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE inv supplier_invoices%ROWTYPE; v_sup text; r record; v_item bigint; v_name text; v_qty numeric; v_res jsonb; v_note text;
  v_add jsonb := '[]'; v_miss jsonb := '[]'; v_done jsonb; v_seen text[] := '{}'; v_key text;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in'; END IF;
  SELECT * INTO inv FROM supplier_invoices WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice not found'; END IF;
  SELECT name INTO v_sup FROM suppliers WHERE id = inv.supplier_id;
  -- already added (and not undone)?
  SELECT jsonb_agg(jsonb_build_object('item', p.name, 'qty', s.quantity, 'place', l.name, 'at', s.added_at,
           'by', (SELECT u.login_email::text FROM app_users u WHERE u.id = s.added_by)) ORDER BY s.line_no) INTO v_done
  FROM supplier_invoice_stock s JOIN pricebook_items p ON p.id = s.item_id LEFT JOIN stock_locations l ON l.id = s.location_id
  LEFT JOIN inventory_transactions t ON t.id = s.txn_id
  WHERE s.supplier_invoice_id = p_id AND (s.txn_id IS NULL OR t.undone_at IS NULL);
  IF v_done IS NOT NULL THEN
    IF NOT p_dry THEN RAISE EXCEPTION 'These parts were already added to our stock'; END IF;
    RETURN jsonb_build_object('done', v_done, 'add', '[]'::jsonb, 'miss', '[]'::jsonb);
  END IF;
  IF coalesce(inv.doc_type, 'invoice') <> 'invoice' OR coalesce(inv.total, 0) < 0 THEN
    IF NOT p_dry THEN RAISE EXCEPTION 'This is not an invoice for parts, so nothing can be added to stock'; END IF;
    RETURN jsonb_build_object('done', NULL, 'add', '[]'::jsonb, 'miss', '[]'::jsonb, 'not_invoice', true);
  END IF;
  IF NOT p_dry AND NOT EXISTS (SELECT 1 FROM stock_locations WHERE id = p_place AND active) THEN RAISE EXCEPTION 'Pick where the stock goes'; END IF;
  v_note := 'From supplier invoice ' || coalesce(inv.supplier_invoice_number, '#' || p_id) || coalesce(' (' || v_sup || ')', '');
  FOR r IN SELECT x.ord::int AS n, btrim(coalesce(x.l ->> 'code', '')) AS code, x.l ->> 'description' AS descr,
                  CASE WHEN coalesce(x.l ->> 'shipped', x.l ->> 'ordered', x.l ->> 'quantity') ~ '^-?[0-9]+(\.[0-9]+)?$'
                       THEN coalesce(x.l ->> 'shipped', x.l ->> 'ordered', x.l ->> 'quantity')::numeric END AS qty
           FROM jsonb_array_elements(CASE WHEN jsonb_typeof(inv.lines) = 'array' THEN inv.lines ELSE '[]'::jsonb END) WITH ORDINALITY x(l, ord)
  LOOP
    CONTINUE WHEN r.code = '' OR r.qty IS NULL OR r.qty <= 0 OR r.qty > 100000;
    v_key := lower(r.code) || '|' || r.qty || '|' || lower(coalesce(r.descr, ''));   -- a line read twice off the scan counts once
    CONTINUE WHEN v_key = ANY (v_seen); v_seen := v_seen || v_key;
    v_item := NULL;
    SELECT si.item_id INTO v_item FROM supplier_items si JOIN pricebook_items p ON p.id = si.item_id AND p.active IS NOT FALSE
      WHERE si.supplier_id = inv.supplier_id AND lower(btrim(si.supplier_sku)) = lower(r.code) ORDER BY si.is_preferred DESC NULLS LAST, si.id LIMIT 1;
    IF v_item IS NULL THEN
      SELECT p.id INTO v_item FROM pricebook_items p WHERE lower(btrim(p.sku)) = lower(r.code) AND p.active IS NOT FALSE
        ORDER BY p.track_inventory DESC NULLS LAST, (p.item_type = 'material') DESC, p.id LIMIT 1;
    END IF;
    IF v_item IS NULL THEN
      v_miss := v_miss || jsonb_build_object('code', r.code, 'description', r.descr, 'qty', r.qty); CONTINUE;
    END IF;
    SELECT name INTO v_name FROM pricebook_items WHERE id = v_item;
    IF NOT p_dry THEN
      v_res := public.stock_move(jsonb_build_object('item', v_item, 'kind', 'in', 'place', p_place, 'qty', r.qty, 'note', v_note));
      INSERT INTO supplier_invoice_stock (supplier_invoice_id, line_no, item_id, quantity, txn_id, location_id, added_by)
      VALUES (p_id, r.n, v_item, r.qty, (v_res ->> 'txn')::bigint, p_place, public.current_app_user_id());
    END IF;
    v_add := v_add || jsonb_build_object('code', r.code, 'description', r.descr, 'qty', r.qty, 'item_id', v_item, 'item', v_name);
  END LOOP;
  IF NOT p_dry AND jsonb_array_length(v_add) = 0 THEN RAISE EXCEPTION 'None of these parts are in our price list, so nothing was added'; END IF;
  RETURN jsonb_build_object('done', NULL, 'add', v_add, 'miss', v_miss, 'added', NOT p_dry,
    'place', (SELECT name FROM stock_locations WHERE id = p_place));
END $$;
REVOKE ALL ON FUNCTION public.supplier_invoice_to_stock(bigint, bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_to_stock(bigint, bigint, boolean) TO authenticated;

-- Speed round 3 (Carlo, Nov 19, 2026): the sync's own jobs.
-- (1) rebuild_search_index no longer empties the find-anything list and fills it again
--     (TRUNCATE + about 470,000 rows on every sync, which locked the search for about 20 seconds
--     and rewrote 111 MB each time). It now works the list out beside the real one and only
--     changes the lines that are different: lines that are gone are removed, new ones are added,
--     changed ones are changed. The search is never locked and never empty.
--     The old way is kept as rebuild_search_index_old(), in case it is ever needed.

CREATE OR REPLACE FUNCTION public.rebuild_search_index_old()
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE n bigint;
BEGIN
  TRUNCATE search_index;

  INSERT INTO search_index (entity_type, entity_id, title, subtitle, search_text, customer_id)
  SELECT 'customer', c.id, c.display_name, c.customer_number,
         lower(concat_ws(' ', c.display_name, c.company_name, c.customer_number, c.st_id,
               (SELECT string_agg(cc.value || ' ' || cc.value_digits, ' ') FROM customer_contacts cc WHERE cc.customer_id = c.id),
               (SELECT string_agg(concat_ws(' ', l.street, l.city, l.postal_code), ' ') FROM locations l WHERE l.customer_id = c.id))),
         c.id
  FROM customers c;

  INSERT INTO search_index
  SELECT 'job', j.id, 'Job ' || j.job_number, left(j.summary, 80),
         lower(concat_ws(' ', j.job_number, j.st_id, j.partner_reference, j.partner_receipt_number,
               j.authorization_number, j.po_number, j.claim_number)),
         j.customer_id, now()
  FROM jobs j;

  INSERT INTO search_index
  SELECT 'invoice', i.id, 'Invoice ' || i.invoice_number, to_char(i.total, 'FM$999,999,990.00'),
         lower(concat_ws(' ', i.invoice_number, i.st_id, i.po_number, i.claim_number, i.authorization_number)),
         i.customer_id, now()
  FROM invoices i;

  INSERT INTO search_index
  SELECT 'estimate', e.id, 'Estimate ' || e.estimate_number, e.status,
         lower(concat_ws(' ', e.estimate_number, e.st_id)), e.customer_id, now()
  FROM estimates e;

  INSERT INTO search_index
  SELECT 'equipment', e.id, concat_ws(' ', et.name, e.model_number), 'S/N ' || e.serial_number,
         lower(concat_ws(' ', e.model_number, e.serial_number, e.st_id,
               (SELECT string_agg(concat_ws(' ', w.registration_number, w.contract_number), ' ')
                  FROM warranty_coverages w WHERE w.equipment_id = e.id))),
         l.customer_id, now()
  FROM equipment e JOIN equipment_types et ON et.id = e.equipment_type_id JOIN locations l ON l.id = e.location_id;

  INSERT INTO search_index
  SELECT 'payment', p.id, 'Payment ' || p.payment_number, to_char(p.amount, 'FM$999,999,990.00'),
         lower(concat_ws(' ', p.payment_number, p.reference, p.processor_transaction_id)), p.customer_id, now()
  FROM payments p;

  INSERT INTO search_index
  SELECT 'purchase_order', po.id, 'PO ' || po.po_number, s.name,
         lower(concat_ws(' ', po.po_number, po.supplier_reference, po.st_id)), NULL, now()
  FROM purchase_orders po JOIN suppliers s ON s.id = po.supplier_id;

  INSERT INTO search_index
  SELECT 'permit', p.id, 'Permit ' || coalesce(p.permit_number, '(not issued)'), p.permit_type,
         lower(coalesce(p.permit_number, '')), j.customer_id, now()
  FROM permits p LEFT JOIN jobs j ON j.id = p.job_id;

  INSERT INTO search_index
  SELECT 'manufacturer_claim', mc.id, 'Mfr claim ' || coalesce(mc.portal_claim_number, mc.id::text), mc.status,
         lower(concat_ws(' ', mc.portal_claim_number, mc.serial_number, mc.model_number)), j.customer_id, now()
  FROM manufacturer_warranty_claims mc JOIN jobs j ON j.id = mc.job_id;

  INSERT INTO search_index
  SELECT 'supplier_claim', sc.id, 'Supplier claim ' || sc.claim_number, sc.status,
         lower(concat_ws(' ', sc.claim_number, sc.supplier_claim_reference, sc.failed_part_serial)),
         j.customer_id, now()
  FROM supplier_warranty_claims sc LEFT JOIN jobs j ON j.id = sc.job_id;

  SELECT count(*) INTO n FROM search_index;
  RETURN n;
END $function$;
REVOKE EXECUTE ON FUNCTION public.rebuild_search_index_old() FROM PUBLIC, anon, authenticated;

-- what the find-anything list should hold right now (the same ten look-ups as the old way, word for word)
CREATE OR REPLACE FUNCTION public._search_index_calc()
 RETURNS TABLE (entity_type text, entity_id bigint, title text, subtitle text, search_text text, customer_id bigint)
 LANGUAGE sql STABLE
AS $function$
  SELECT 'customer'::text, c.id, c.display_name::text, c.customer_number::text,
         lower(concat_ws(' ', c.display_name, c.company_name, c.customer_number, c.st_id,
               (SELECT string_agg(cc.value || ' ' || cc.value_digits, ' ') FROM customer_contacts cc WHERE cc.customer_id = c.id),
               (SELECT string_agg(concat_ws(' ', l.street, l.city, l.postal_code), ' ') FROM locations l WHERE l.customer_id = c.id))),
         c.id
  FROM customers c
  UNION ALL
  SELECT 'job', j.id, ('Job ' || j.job_number)::text, left(j.summary, 80)::text,
         lower(concat_ws(' ', j.job_number, j.st_id, j.partner_reference, j.partner_receipt_number,
               j.authorization_number, j.po_number, j.claim_number)),
         j.customer_id
  FROM jobs j
  UNION ALL
  SELECT 'invoice', i.id, ('Invoice ' || i.invoice_number)::text, to_char(i.total, 'FM$999,999,990.00'),
         lower(concat_ws(' ', i.invoice_number, i.st_id, i.po_number, i.claim_number, i.authorization_number)),
         i.customer_id
  FROM invoices i
  UNION ALL
  SELECT 'estimate', e.id, ('Estimate ' || e.estimate_number)::text, e.status::text,
         lower(concat_ws(' ', e.estimate_number, e.st_id)), e.customer_id
  FROM estimates e
  UNION ALL
  SELECT 'equipment', e.id, concat_ws(' ', et.name, e.model_number), ('S/N ' || e.serial_number)::text,
         lower(concat_ws(' ', e.model_number, e.serial_number, e.st_id,
               (SELECT string_agg(concat_ws(' ', w.registration_number, w.contract_number), ' ')
                  FROM warranty_coverages w WHERE w.equipment_id = e.id))),
         l.customer_id
  FROM equipment e JOIN equipment_types et ON et.id = e.equipment_type_id JOIN locations l ON l.id = e.location_id
  UNION ALL
  SELECT 'payment', p.id, ('Payment ' || p.payment_number)::text, to_char(p.amount, 'FM$999,999,990.00'),
         lower(concat_ws(' ', p.payment_number, p.reference, p.processor_transaction_id)), p.customer_id
  FROM payments p
  UNION ALL
  SELECT 'purchase_order', po.id, ('PO ' || po.po_number)::text, s.name::text,
         lower(concat_ws(' ', po.po_number, po.supplier_reference, po.st_id)), NULL::bigint
  FROM purchase_orders po JOIN suppliers s ON s.id = po.supplier_id
  UNION ALL
  SELECT 'permit', p.id, ('Permit ' || coalesce(p.permit_number, '(not issued)'))::text, p.permit_type::text,
         lower(coalesce(p.permit_number, '')), j.customer_id
  FROM permits p LEFT JOIN jobs j ON j.id = p.job_id
  UNION ALL
  SELECT 'manufacturer_claim', mc.id, ('Mfr claim ' || coalesce(mc.portal_claim_number, mc.id::text))::text, mc.status::text,
         lower(concat_ws(' ', mc.portal_claim_number, mc.serial_number, mc.model_number)), j.customer_id
  FROM manufacturer_warranty_claims mc JOIN jobs j ON j.id = mc.job_id
  UNION ALL
  SELECT 'supplier_claim', sc.id, ('Supplier claim ' || sc.claim_number)::text, sc.status::text,
         lower(concat_ws(' ', sc.claim_number, sc.supplier_claim_reference, sc.failed_part_serial)),
         j.customer_id
  FROM supplier_warranty_claims sc LEFT JOIN jobs j ON j.id = sc.job_id
$function$;
REVOKE EXECUTE ON FUNCTION public._search_index_calc() FROM PUBLIC, anon, authenticated;

-- the last run's counts, to read with SQL: select * from search_index_runs order by at desc limit 5
CREATE TABLE IF NOT EXISTS public.search_index_runs (
  at timestamptz NOT NULL DEFAULT now(), total bigint, removed bigint, added bigint, changed bigint, ms integer);
ALTER TABLE public.search_index_runs ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.rebuild_search_index()
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE n bigint; n_del bigint; n_ins bigint; n_upd bigint; t0 timestamptz := clock_timestamp();
BEGIN
  DROP TABLE IF EXISTS pg_temp._si_new;
  CREATE TEMP TABLE _si_new ON COMMIT DROP AS SELECT * FROM public._search_index_calc();
  CREATE UNIQUE INDEX ON _si_new (entity_type, entity_id);
  ANALYZE _si_new;

  DELETE FROM search_index s
   WHERE NOT EXISTS (SELECT 1 FROM _si_new x WHERE x.entity_type = s.entity_type AND x.entity_id = s.entity_id);
  GET DIAGNOSTICS n_del = ROW_COUNT;

  UPDATE search_index s
     SET title = x.title, subtitle = x.subtitle, search_text = x.search_text, customer_id = x.customer_id, refreshed_at = now()
    FROM _si_new x
   WHERE x.entity_type = s.entity_type AND x.entity_id = s.entity_id
     AND (s.title, s.subtitle, s.search_text, s.customer_id) IS DISTINCT FROM (x.title, x.subtitle, x.search_text, x.customer_id);
  GET DIAGNOSTICS n_upd = ROW_COUNT;

  INSERT INTO search_index (entity_type, entity_id, title, subtitle, search_text, customer_id, refreshed_at)
  SELECT x.entity_type, x.entity_id, x.title, x.subtitle, x.search_text, x.customer_id, now()
    FROM _si_new x
   WHERE NOT EXISTS (SELECT 1 FROM search_index s WHERE s.entity_type = x.entity_type AND s.entity_id = x.entity_id)
  ON CONFLICT (entity_type, entity_id) DO UPDATE
     SET title = EXCLUDED.title, subtitle = EXCLUDED.subtitle, search_text = EXCLUDED.search_text,
         customer_id = EXCLUDED.customer_id, refreshed_at = now();
  GET DIAGNOSTICS n_ins = ROW_COUNT;

  SELECT count(*) INTO n FROM _si_new;
  DROP TABLE IF EXISTS pg_temp._si_new;
  BEGIN
    INSERT INTO public.search_index_runs (total, removed, added, changed, ms)
    VALUES (n, n_del, n_ins, n_upd, (extract(epoch FROM clock_timestamp() - t0) * 1000)::int);
    DELETE FROM public.search_index_runs WHERE at < now() - interval '60 days';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  RETURN n;
END $function$;

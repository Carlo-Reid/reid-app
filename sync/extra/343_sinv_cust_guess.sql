-- A supplier's paper is tied to the customer's invoice by what is written on it, when its P.O. does not say (Carlo, Nov 26, 2026: "If we get an Invoice
-- then we need to match it against a P.O. and connect it to a customer or put it in stock").
-- Three ways, strongest first; only when exactly one customer fits:
--   serial  : "Serial#: <its serial number>" in what was read (Lennox prints it on extended warranty papers) = an equipment record of ours -> its customer
--   address : the P.O. box holds an address ("284 BAYSWATER") and the paper has no P.O. -> one customer address
--   name    : the P.O. box holds only a name (a last name) and the paper has no P.O. -> one customer with that word in the name who had a job in the 180 days before
-- Then the customer's invoice: the install job's invoice of that equipment, else the customer's invoice nearest the paper's date (180 days before to 60 after),
-- the same address first. A pair a person took off (supplier_invoice_customer_unlinks) is never put back. Each tie is kept in sinv_cust_guess with how.
CREATE TABLE IF NOT EXISTS public.sinv_cust_guess (supplier_invoice_id bigint NOT NULL, invoice_id bigint NOT NULL, how text NOT NULL,
  made_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (supplier_invoice_id, invoice_id));
ALTER TABLE public.sinv_cust_guess ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sinv_cust_guess FROM PUBLIC, anon, authenticated;
CREATE INDEX IF NOT EXISTS equipment_serial_up ON public.equipment (upper(serial_number));

CREATE OR REPLACE FUNCTION public._sinv_cust_guess(p_id bigint DEFAULT NULL) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int;
BEGIN
  DROP TABLE IF EXISTS _sinv_cg;
  CREATE TEMP TABLE _sinv_cg ON COMMIT DROP AS
  WITH s AS (SELECT si.id, si.invoice_date AS d, si.po_text, si.read_notes,
                    upper(substring(si.read_notes FROM '(?i)serial\s*#?\s*:\s*([A-Z0-9]{6,})')) AS ser,
                    nullif(lower(substring(si.po_text FROM '^\s*(\d{1,5}\s+[A-Za-z]{3,})')), '') AS adr,
                    CASE WHEN trim(si.po_text) ~ '^[A-Za-z][A-Za-z'' -]{3,}\Z'
                          AND upper(trim(si.po_text)) !~ '(^|\s)(RETURNS?|WARRANTY|STOCK|SHOP|TRUCK|CREDIT|CORE|TANK|TANKS|SERVICE|INSTALL|PARTS?|OFFICE|WAREHOUSE|COSTCO|VISTA|RONA|REID|HSG|HOME|DEPOT|MOTOR FAILURE|CHURCH)(\s|\Z)'
                          AND NOT EXISTS (SELECT 1 FROM employees em WHERE upper(trim(si.po_text)) IN (upper(em.first_name), upper(em.last_name), upper(em.first_name || ' ' || em.last_name)))
                     THEN upper(trim(si.po_text)) END AS nm
             FROM supplier_invoices si
             WHERE (p_id IS NULL OR si.id = p_id) AND si.invoice_date >= DATE '2025-01-01' AND coalesce(si.doc_type, '') <> 'charge'
               AND NOT EXISTS (SELECT 1 FROM supplier_invoice_customer_links l WHERE l.supplier_invoice_id = si.id)
               AND NOT EXISTS (SELECT 1 FROM supplier_invoice_stock t WHERE t.supplier_invoice_id = si.id)),
  s2 AS (SELECT s.*, CASE WHEN s.adr IS NOT NULL OR s.nm IS NOT NULL THEN (SELECT public._sinv_po(x) FROM supplier_invoices x WHERE x.id = s.id) END AS po_id
         FROM s WHERE s.ser IS NOT NULL OR s.adr IS NOT NULL OR s.nm IS NOT NULL),
  c AS (SELECT s2.id, 1 AS rk, 'serial' AS how, l.customer_id AS cust, l.id AS loc, e.install_job_id AS job
          FROM s2 JOIN equipment e ON upper(e.serial_number) = s2.ser JOIN locations l ON l.id = e.location_id WHERE s2.ser IS NOT NULL
        UNION ALL
        SELECT s2.id, 2, 'address', l.customer_id, l.id, NULL FROM s2
          JOIN LATERAL (SELECT l.* FROM locations l WHERE lower(l.street) LIKE s2.adr || '%') l ON true
          WHERE s2.po_id IS NULL AND s2.adr IS NOT NULL
        UNION ALL
        SELECT s2.id, 3, 'name', cu.id, NULL, NULL FROM s2
          JOIN LATERAL (SELECT cu.id FROM customers cu WHERE cu.display_name ILIKE '%' || s2.nm || '%'
                          AND upper(cu.display_name) ~ ('(^|[^A-Z])' || s2.nm || '([^A-Z]|\Z)')) cu ON true
          WHERE s2.po_id IS NULL AND s2.nm IS NOT NULL
            AND EXISTS (SELECT 1 FROM jobs j WHERE j.customer_id = cu.id AND j.created_at BETWEEN s2.d - interval '180 days' AND s2.d + interval '30 days')),
  one AS (SELECT id, rk, how, min(cust) AS cust, min(loc) AS loc, max(job) AS job FROM c GROUP BY id, rk, how HAVING count(DISTINCT cust) = 1),
  best AS (SELECT DISTINCT ON (id) * FROM one ORDER BY id, rk),
  pick AS (SELECT b.id, b.how, coalesce(
             (SELECT i.id FROM invoices i WHERE b.job IS NOT NULL AND i.job_id = b.job AND coalesce(i.status, '') <> 'void' AND i.deleted_at IS NULL ORDER BY i.invoice_date, i.id LIMIT 1),
             (SELECT i.id FROM invoices i LEFT JOIN jobs j ON j.id = i.job_id
               WHERE i.customer_id = b.cust AND coalesce(i.status, '') <> 'void' AND i.deleted_at IS NULL
                 AND i.invoice_date BETWEEN s.d - interval '180 days' AND s.d + interval '60 days'
               ORDER BY (b.loc IS NOT NULL AND j.location_id = b.loc) DESC, abs(i.invoice_date - s.d), i.id LIMIT 1)) AS inv
           FROM best b JOIN s2 s ON s.id = b.id)
  SELECT id, how, inv FROM pick WHERE inv IS NOT NULL;
  DELETE FROM _sinv_cg g WHERE EXISTS (SELECT 1 FROM supplier_invoice_customer_unlinks u WHERE u.supplier_invoice_id = g.id AND u.invoice_id = g.inv);
  INSERT INTO supplier_invoice_customer_links (supplier_invoice_id, invoice_id, linked_by, auto) SELECT id, inv, NULL, true FROM _sinv_cg ON CONFLICT DO NOTHING;
  INSERT INTO sinv_cust_guess (supplier_invoice_id, invoice_id, how) SELECT id, inv, how FROM _sinv_cg ON CONFLICT DO NOTHING;
  SELECT count(*) INTO n FROM _sinv_cg;
  RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public._sinv_cust_guess(bigint) FROM PUBLIC, anon, authenticated;

-- A supplier's credit is tied to the real customer too (Carlo, Nov 26, 2026: "If we get a Credit Order from them then we need to ... connect it to a customer"):
--   warranty note : the credit is tied to a "Lennox - Warranty Credit" invoice whose note ends with the customer and address ("<first and last name> <street number and street>")
--                   -> one customer address -> that customer's invoice nearest the credit's date (a year before to 60 days after)
--   costco name   : a Costco payment line ("COSTCO PAYMENTS <order>-<LASTNAME>-<FIRSTNAME>") -> one customer with both names -> their invoice nearest the date
CREATE OR REPLACE FUNCTION public._scredit_cust_guess(p_id bigint DEFAULT NULL) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int; v_wc bigint;
BEGIN
  v_wc := public._wc_customer();
  DROP TABLE IF EXISTS _scr_cg;
  CREATE TEMP TABLE _scr_cg ON COMMIT DROP AS
  WITH cr AS (SELECT si.id, si.invoice_date AS d, si.lines FROM supplier_invoices si
              WHERE (p_id IS NULL OR si.id = p_id) AND si.invoice_date >= DATE '2025-01-01' AND (si.doc_type IN ('credit', 'return') OR si.total < 0)
                AND NOT EXISTS (SELECT 1 FROM supplier_invoice_customer_links l JOIN invoices i ON i.id = l.invoice_id
                                WHERE l.supplier_invoice_id = si.id AND i.customer_id IS DISTINCT FROM v_wc)),
  wn AS (SELECT cr.id, cr.d, lower(m[1] || ' ' || m[2]) AS adr FROM cr
           JOIN supplier_invoice_customer_links l ON l.supplier_invoice_id = cr.id
           JOIN invoices wi ON wi.id = l.invoice_id AND wi.customer_id = v_wc
           JOIN invoice_lines il ON il.invoice_id = wi.id
           CROSS JOIN LATERAL regexp_matches(coalesce(il.description, ''), '(?:^|\s)(\d{1,5})\s+([A-Za-z]{3,})', 'g') m),
  c AS (SELECT wn.id, wn.d, 'warranty note' AS how, l.customer_id AS cust, l.id AS loc FROM wn
          JOIN LATERAL (SELECT l.* FROM locations l WHERE lower(l.street) LIKE wn.adr || '%') l ON true
        UNION ALL
        SELECT cr.id, cr.d, 'costco name', cu.id, NULL FROM cr
          CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(cr.lines) = 'array' THEN cr.lines ELSE '[]'::jsonb END) e
          CROSS JOIN LATERAL regexp_matches(coalesce(e->>'description', ''), 'COSTCO PAYMENTS\s+\S+-\d+-([A-Z'']{2,})-([A-Z'']{2,})') m
          JOIN LATERAL (SELECT min(cu.id) AS id, count(*) AS k FROM customers cu WHERE cu.display_name ILIKE '%' || m[1] || '%' AND cu.display_name ILIKE '%' || m[2] || '%') cu ON cu.k = 1),
  grp AS (SELECT id, how, min(d) AS d, cust, min(loc) AS loc FROM c GROUP BY id, how, cust),
  okc AS (SELECT g.* FROM grp g WHERE g.how = 'costco name'
            OR (SELECT count(DISTINCT g2.cust) FROM grp g2 WHERE g2.id = g.id AND g2.how = 'warranty note') = 1),
  pick AS (SELECT o.id, o.how, (SELECT i.id FROM invoices i LEFT JOIN jobs j ON j.id = i.job_id
             WHERE i.customer_id = o.cust AND coalesce(i.status, '') <> 'void' AND i.deleted_at IS NULL
               AND i.invoice_date BETWEEN o.d - interval '365 days' AND o.d + interval '60 days'
             ORDER BY (o.loc IS NOT NULL AND j.location_id = o.loc) DESC, abs(i.invoice_date - o.d), i.id LIMIT 1) AS inv FROM okc o)
  SELECT DISTINCT id, how, inv FROM pick WHERE inv IS NOT NULL;
  DELETE FROM _scr_cg g WHERE EXISTS (SELECT 1 FROM supplier_invoice_customer_unlinks u WHERE u.supplier_invoice_id = g.id AND u.invoice_id = g.inv);
  INSERT INTO supplier_invoice_customer_links (supplier_invoice_id, invoice_id, linked_by, auto) SELECT id, inv, NULL, true FROM _scr_cg ON CONFLICT DO NOTHING;
  INSERT INTO sinv_cust_guess (supplier_invoice_id, invoice_id, how) SELECT id, inv, how FROM _scr_cg ON CONFLICT DO NOTHING;
  SELECT count(*) INTO n FROM _scr_cg;
  RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public._scredit_cust_guess(bigint) FROM PUBLIC, anon, authenticated;

-- the nightly tie runs it after the P.O. ties
CREATE OR REPLACE FUNCTION public._sinv_autolink(p_job bigint DEFAULT NULL) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int;
BEGIN
  IF p_job IS NULL THEN BEGIN PERFORM public._bank_supplier_payments(); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'bank payments: %', SQLERRM; END; END IF;
  IF p_job IS NULL THEN BEGIN PERFORM public._po_guess_jobs(); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'po guess: %', SQLERRM; END; END IF;
  WITH sp AS (SELECT s.id, coalesce(po.job_id, g.job_id) AS job_id FROM supplier_invoices s CROSS JOIN LATERAL (SELECT public._sinv_po(s) AS po_id) x
              JOIN purchase_orders po ON po.id = x.po_id LEFT JOIN po_job_guess g ON g.po_id = po.id
              WHERE coalesce(po.job_id, g.job_id) IS NOT NULL AND (p_job IS NULL OR coalesce(po.job_id, g.job_id) = p_job)),
       ins AS (INSERT INTO supplier_invoice_customer_links (supplier_invoice_id, invoice_id, linked_by, auto)
               SELECT sp.id, i.id, NULL, true FROM sp JOIN invoices i ON i.job_id = sp.job_id AND coalesce(i.status, '') <> 'void'
               WHERE NOT EXISTS (SELECT 1 FROM supplier_invoice_customer_unlinks u WHERE u.supplier_invoice_id = sp.id AND u.invoice_id = i.id)
               ON CONFLICT DO NOTHING RETURNING 1)
  SELECT count(*) INTO n FROM ins;
  IF p_job IS NULL THEN BEGIN n := n + public._sinv_cust_guess(NULL); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'sinv cust guess: %', SQLERRM; END;
    BEGIN n := n + public._scredit_cust_guess(NULL); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'credit cust guess: %', SQLERRM; END; END IF;
  IF p_job IS NULL THEN BEGIN PERFORM public._po_suggest_jobs(); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'po suggest: %', SQLERRM; END;
    BEGIN PERFORM public._sinv_suggest_jobs(); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'sinv suggest: %', SQLERRM; END; END IF;
  RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public._sinv_autolink(bigint) FROM PUBLIC, anon, authenticated;

-- a new or re-read paper is tied right away, not only at night
CREATE OR REPLACE FUNCTION public._trg_sinv_cust_guess() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  BEGIN PERFORM public._sinv_cust_guess(NEW.id); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'sinv cust guess: %', SQLERRM; END;
  BEGIN PERFORM public._scredit_cust_guess(NEW.id); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'credit cust guess: %', SQLERRM; END;
  RETURN NULL;
END $f$;
DROP TRIGGER IF EXISTS trg_sinv_cust_guess ON public.supplier_invoices;
CREATE TRIGGER trg_sinv_cust_guess AFTER INSERT OR UPDATE OF read_notes, po_text, purchase_order_id ON public.supplier_invoices
  FOR EACH ROW EXECUTE FUNCTION public._trg_sinv_cust_guess();

-- a credit tied to the "Lennox - Warranty Credit" invoice (the Warranty credits page) finds the real customer right away
CREATE OR REPLACE FUNCTION public._trg_scl_warranty() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF EXISTS (SELECT 1 FROM invoices i WHERE i.id = NEW.invoice_id AND i.customer_id = public._wc_customer()) THEN
    BEGIN PERFORM public._scredit_cust_guess(NEW.supplier_invoice_id); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'credit cust guess: %', SQLERRM; END;
  END IF;
  RETURN NULL;
END $f$;
DROP TRIGGER IF EXISTS trg_scl_warranty ON public.supplier_invoice_customer_links;
CREATE TRIGGER trg_scl_warranty AFTER INSERT ON public.supplier_invoice_customer_links FOR EACH ROW EXECUTE FUNCTION public._trg_scl_warranty();

-- the open supplier invoice says how a tie was found
CREATE OR REPLACE FUNCTION public.sinv_cust_invoices(p_id bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE s supplier_invoices; v_job bigint;
BEGIN
  IF NOT public._can_see_costs() THEN RAISE EXCEPTION 'You need to be able to see costs for this'; END IF;
  SELECT * INTO s FROM supplier_invoices WHERE id = p_id; IF s.id IS NULL THEN RAISE EXCEPTION 'Not found'; END IF;
  SELECT job_id INTO v_job FROM purchase_orders WHERE id = public._sinv_po(s);
  RETURN jsonb_build_object(
    'linked', (SELECT coalesce(jsonb_agg(public._sinv_cinv(i) || jsonb_build_object('by', public._emp_name((SELECT employee_id FROM app_users WHERE id = k.linked_by)), 'at', k.linked_at,
                 'how', (SELECT g.how FROM sinv_cust_guess g WHERE g.supplier_invoice_id = p_id AND g.invoice_id = i.id)) ORDER BY i.invoice_date, i.id), '[]')
               FROM supplier_invoice_customer_links k JOIN invoices i ON i.id = k.invoice_id WHERE k.supplier_invoice_id = p_id),
    'suggest', (SELECT coalesce(jsonb_agg(public._sinv_cinv(i) ORDER BY i.invoice_date DESC, i.id DESC), '[]') FROM invoices i
                WHERE v_job IS NOT NULL AND i.job_id = v_job AND coalesce(i.status, '') <> 'void'
                  AND NOT EXISTS (SELECT 1 FROM supplier_invoice_customer_links k WHERE k.supplier_invoice_id = p_id AND k.invoice_id = i.id)));
END $function$;

DO $$ DECLARE n int; BEGIN n := public._sinv_cust_guess(NULL) + public._scredit_cust_guess(NULL); RAISE NOTICE 'supplier papers tied by what is written on them: %', n; END $$;
NOTIFY pgrst, 'reload schema';

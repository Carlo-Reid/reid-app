-- =====================================================================
-- Supplier invoices with no customer invoice: suggest the job they were for, to be checked by hand.
-- Clues, in this order (the first one that fits wins), from the PO box, the job name, and the PO's summary/notes:
--   1. a job number written on it (8-9 digits that is one of our jobs)                         → sure
--   2. a street address ("1355 Pebble rd") matching one customer address that has a job
--      from 60 days before to 90 days after the supplier invoice's date                        → sure (one job) / likely (more jobs there; the nearest)
--   3. a customer name: first + last name together, or a last name alone, belonging to just one
--      customer with a job within 45 days of the date (staff names and common words are skipped) → likely (two names) / maybe (one name)
-- Only jobs that have an invoice (not void) count. Nothing is attached until someone accepts it on the Supplier invoices page.
-- A suggestion turned down is remembered and not made again. Runs with each sync and every 10 minutes after the supplier mail.
-- Safe to run more than once.
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.sinv_job_suggest (
  supplier_invoice_id bigint PRIMARY KEY REFERENCES public.supplier_invoices(id) ON DELETE CASCADE,
  job_id bigint NOT NULL, how text NOT NULL, conf text NOT NULL CHECK (conf IN ('sure', 'likely', 'maybe')),
  made_at timestamptz NOT NULL DEFAULT now(),
  decided text CHECK (decided IN ('accepted', 'rejected')), decided_by bigint, decided_at timestamptz);
CREATE INDEX IF NOT EXISTS sinv_job_suggest_open ON public.sinv_job_suggest (conf) WHERE decided IS NULL;
ALTER TABLE public.sinv_job_suggest ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sinv_job_suggest FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._sinv_suggest_jobs() RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int;
BEGIN
  PERFORM set_config('client_min_messages', 'warning', true);
  -- the supplier invoices to look at: no customer invoice, no open or turned-down suggestion
  DROP TABLE IF EXISTS _sg_u;
  CREATE TEMP TABLE _sg_u ON COMMIT DROP AS
    SELECT s.id, po.po_number, coalesce(s.invoice_date, po.ordered_at::date, s.created_at::date) AS d,
           concat_ws(' / ', s.po_text, s.job_name, po.description, CASE WHEN po.notes IS DISTINCT FROM po.description THEN po.notes END) AS t
    FROM supplier_invoices s LEFT JOIN purchase_orders po ON po.id = public._sinv_po(s)
    WHERE NOT EXISTS (SELECT 1 FROM supplier_invoice_customer_links k WHERE k.supplier_invoice_id = s.id)
      AND NOT EXISTS (SELECT 1 FROM sinv_job_suggest g WHERE g.supplier_invoice_id = s.id AND g.decided IS DISTINCT FROM 'accepted')
      AND (po.id IS NULL OR po.job_id IS NULL);
  DELETE FROM _sg_u WHERE btrim(coalesce(t, '')) = '' OR d IS NULL;
  IF NOT EXISTS (SELECT 1 FROM _sg_u) THEN RETURN 0; END IF;

  -- jobs that have an invoice, with the date they happened
  DROP TABLE IF EXISTS _sg_j;
  CREATE TEMP TABLE _sg_j ON COMMIT DROP AS
    SELECT j.id, j.job_number::text AS job_number, j.customer_id, j.location_id, coalesce(j.completed_at, j.created_at)::date AS jd
    FROM jobs j WHERE EXISTS (SELECT 1 FROM invoices i WHERE i.job_id = j.id AND coalesce(i.status, '') <> 'void');
  CREATE INDEX ON _sg_j (job_number); CREATE INDEX ON _sg_j (location_id); CREATE INDEX ON _sg_j (customer_id);

  DROP TABLE IF EXISTS _sg_m;
  CREATE TEMP TABLE _sg_m (id bigint PRIMARY KEY, job_id bigint, how text, conf text) ON COMMIT DROP;

  -- 1. a job number on it
  INSERT INTO _sg_m
  SELECT DISTINCT ON (u.id) u.id, j.id, 'job # ' || j.job_number, 'sure'
  FROM _sg_u u CROSS JOIN LATERAL regexp_matches(u.t, '(?:^|[^0-9])([0-9]{8,9})(?![0-9])', 'g') m
  JOIN _sg_j j ON j.job_number = m[1]
  WHERE m[1] IS DISTINCT FROM u.po_number
  ORDER BY u.id, abs(j.jd - u.d);

  -- 2. a street address on it
  DROP TABLE IF EXISTS _sg_lk;
  CREATE TEMP TABLE _sg_lk ON COMMIT DROP AS
    SELECT l.id, m[1] || ' ' || m[2] AS k
    FROM locations l CROSS JOIN LATERAL regexp_match(lower(coalesce(l.street, '')), '^([0-9]{1,5})[a-z]?\s+(?:(?:rue|ch|chemin|de|du|la|le|st|ste|saint)\s+)?([a-z]{3,})') m
    WHERE m IS NOT NULL;
  CREATE INDEX ON _sg_lk (k);
  INSERT INTO _sg_m
  SELECT x.id, x.job_id, 'address ' || x.k, CASE WHEN x.njobs = 1 THEN 'sure' ELSE 'likely' END
  FROM (SELECT u.id, a.k, j.id AS job_id,
               count(*) OVER (PARTITION BY u.id, a.k) AS njobs, (min(j.location_id) OVER (PARTITION BY u.id, a.k) = max(j.location_id) OVER (PARTITION BY u.id, a.k)) AS oneloc,
               row_number() OVER (PARTITION BY u.id ORDER BY a.pos, abs(j.jd - u.d), j.id) AS rn,
               min(a.pos) OVER (PARTITION BY u.id) AS firstpos, a.pos
        FROM _sg_u u
        CROSS JOIN LATERAL (SELECT DISTINCT ON (mm[1] || ' ' || mm[2]) mm[1] || ' ' || mm[2] AS k, ord AS pos
                            FROM regexp_matches(lower(u.t), '(?:^|[^0-9])([0-9]{1,5})[a-z]?\s+([a-z]{3,})', 'g') WITH ORDINALITY AS r(mm, ord)
                            WHERE mm[2] NOT IN ('for', 'and', 'the', 'pcs', 'ton', 'tons', 'btu', 'feet', 'foot', 'inch', 'stock', 'units', 'unit', 'day', 'days', 'pack',
                                                'box', 'boxes', 'amp', 'volt', 'gal', 'gallon', 'pieces', 'sensor', 'sensors', 'zone', 'zones', 'year', 'years', 'month')) a
        JOIN _sg_lk lk ON lk.k = a.k
        JOIN _sg_j j ON j.location_id = lk.id AND j.jd BETWEEN u.d - 60 AND u.d + 90
        WHERE NOT EXISTS (SELECT 1 FROM _sg_m q WHERE q.id = u.id)) x
  WHERE x.rn = 1 AND x.oneloc;

  -- 3. a customer's name on it
  DROP TABLE IF EXISTS _sg_skip;
  CREATE TEMP TABLE _sg_skip (w text PRIMARY KEY) ON COMMIT DROP;
  INSERT INTO _sg_skip SELECT DISTINCT w FROM employees e CROSS JOIN LATERAL regexp_split_to_table(lower(concat_ws(' ', e.first_name, e.last_name)), '[^a-z''-]+') w WHERE length(w) >= 3 ON CONFLICT DO NOTHING;
  INSERT INTO _sg_skip SELECT unnest(string_to_array('warranty return returns stock credit office comfort plan service charge winter fall stocking security alarm demo parts part for and the from with job truck van shop order zone equipment pick picking pickup new old install replace replacement unit furnace boiler filters filter misc renewal street road drive avenue crescent private rental sensor sensors purchase customer house tools board used control personal valve smoke hvac pump detectors ignitor motion switch flue batteries temperature replenishment costco church grand ridge cres court place way lane trail circle blvd boulevard north south east west upper lower main park hill heating cooling plumbing supply supplies inc ltd limited company services service mr mrs ms dr apt unit suite rd ave dr st cr ct pl ln hwy',
    ' ')) ON CONFLICT DO NOTHING;
  DROP TABLE IF EXISTS _sg_cw;
  CREATE TEMP TABLE _sg_cw ON COMMIT DROP AS
    SELECT DISTINCT c.id, w FROM customers c CROSS JOIN LATERAL regexp_split_to_table(lower(coalesce(c.display_name, '')), '[^a-z''-]+') w WHERE length(w) >= 3;
  CREATE INDEX ON _sg_cw (w);
  DROP TABLE IF EXISTS _sg_wc;
  CREATE TEMP TABLE _sg_wc ON COMMIT DROP AS SELECT w, count(*) AS cnt FROM _sg_cw GROUP BY w;
  CREATE INDEX ON _sg_wc (w);
  INSERT INTO _sg_m
  SELECT DISTINCT ON (y.id) y.id, y.job_id, y.how, y.conf
  FROM (
    SELECT x.id, j.id AS job_id, x.how, x.conf, x.pair, (min(j.customer_id) OVER (PARTITION BY x.id, x.how) = max(j.customer_id) OVER (PARTITION BY x.id, x.how)) AS onecust,
           row_number() OVER (PARTITION BY x.id, x.how ORDER BY abs(j.jd - x.d), j.id) AS rn
    FROM (
      -- words in order, as they're written
      WITH ws AS (SELECT u.id, u.d, r.w, r.ord FROM _sg_u u CROSS JOIN LATERAL regexp_split_to_table(lower(u.t), '[^a-z''-]+') WITH ORDINALITY AS r(w, ord)
                  WHERE length(r.w) >= 3 AND NOT EXISTS (SELECT 1 FROM _sg_skip k WHERE k.w = r.w) AND NOT EXISTS (SELECT 1 FROM _sg_m q WHERE q.id = u.id))
      SELECT a.id, a.d, c1.id AS cust, 'name ' || a.w || ' ' || b.w AS how, 'likely' AS conf, true AS pair
      FROM ws a JOIN ws b ON b.id = a.id AND b.ord = a.ord + 1
      JOIN _sg_cw c1 ON c1.w = a.w JOIN _sg_cw c2 ON c2.w = b.w AND c2.id = c1.id
      WHERE (SELECT q.cnt FROM _sg_wc q WHERE q.w = a.w) <= 400 OR (SELECT q.cnt FROM _sg_wc q WHERE q.w = b.w) <= 400
      UNION ALL
      SELECT a.id, a.d, c.id, 'name ' || a.w, 'maybe', false
      FROM ws a JOIN _sg_wc q ON q.w = a.w AND q.cnt <= 400 JOIN _sg_cw c ON c.w = a.w
      WHERE length(a.w) >= 4) x
    JOIN _sg_j j ON j.customer_id = x.cust AND j.jd BETWEEN x.d - 45 AND x.d + 45) y
  WHERE y.rn = 1 AND y.onecust
  ORDER BY y.id, y.pair DESC, y.how;

  INSERT INTO sinv_job_suggest (supplier_invoice_id, job_id, how, conf)
  SELECT id, job_id, how, conf FROM _sg_m
  ON CONFLICT (supplier_invoice_id) DO UPDATE SET job_id = EXCLUDED.job_id, how = EXCLUDED.how, conf = EXCLUDED.conf, made_at = now()
    WHERE sinv_job_suggest.decided IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  -- an open suggestion for one that has since been attached another way isn't needed
  DELETE FROM sinv_job_suggest g WHERE g.decided IS NULL AND EXISTS (SELECT 1 FROM supplier_invoice_customer_links k WHERE k.supplier_invoice_id = g.supplier_invoice_id);
  RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public._sinv_suggest_jobs() FROM PUBLIC, anon, authenticated;

-- the open suggestions, for the Supplier invoices page
CREATE OR REPLACE FUNCTION public.sinv_suggestions() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT (public._sinv_can_edit() AND public._can_see_costs()) THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id', s.id, 'number', s.supplier_invoice_number, 'date', s.invoice_date, 'total', s.total, 'doc_type', s.doc_type,
      'supplier_id', s.supplier_id, 'supplier', btrim(sp.name),
      'text', concat_ws(' / ', s.po_text, s.job_name, po.description, CASE WHEN po.notes IS DISTINCT FROM po.description THEN po.notes END), 'po', po.po_number,
      'job_id', j.id, 'job', j.job_number, 'job_date', coalesce(j.completed_at, j.created_at)::date,
      'customer', c.display_name, 'street', concat_ws(', ', l.street, l.city), 'how', g.how, 'conf', g.conf,
      'invoices', (SELECT jsonb_agg(jsonb_build_object('id', i.id, 'number', i.invoice_number, 'total', i.total) ORDER BY i.invoice_date, i.id)
                   FROM invoices i WHERE i.job_id = j.id AND coalesce(i.status, '') <> 'void'))
      ORDER BY CASE g.conf WHEN 'sure' THEN 1 WHEN 'likely' THEN 2 ELSE 3 END, s.invoice_date DESC NULLS LAST, s.id DESC)
    FROM sinv_job_suggest g JOIN supplier_invoices s ON s.id = g.supplier_invoice_id JOIN suppliers sp ON sp.id = s.supplier_id
    JOIN jobs j ON j.id = g.job_id LEFT JOIN locations l ON l.id = j.location_id LEFT JOIN customers c ON c.id = coalesce(l.customer_id, j.customer_id)
    LEFT JOIN purchase_orders po ON po.id = public._sinv_po(s)
    WHERE g.decided IS NULL), '[]') END $f$;

-- accept (attach to every invoice on the job) or turn down suggestions
CREATE OR REPLACE FUNCTION public.sinv_suggest_decide(p_ids bigint[], p_accept boolean) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int := 0; g record; me bigint := public.current_app_user_id();
BEGIN
  IF NOT (public._sinv_can_edit() AND public._can_see_costs()) THEN RAISE EXCEPTION 'You don''t have permission to change supplier invoices'; END IF;
  FOR g IN SELECT * FROM sinv_job_suggest WHERE supplier_invoice_id = ANY (p_ids) AND decided IS NULL LOOP
    IF p_accept THEN
      INSERT INTO supplier_invoice_customer_links (supplier_invoice_id, invoice_id, linked_by)
      SELECT g.supplier_invoice_id, i.id, me FROM invoices i WHERE i.job_id = g.job_id AND coalesce(i.status, '') <> 'void'
        AND NOT EXISTS (SELECT 1 FROM supplier_invoice_customer_unlinks u WHERE u.supplier_invoice_id = g.supplier_invoice_id AND u.invoice_id = i.id)
      ON CONFLICT DO NOTHING;
    END IF;
    UPDATE sinv_job_suggest SET decided = CASE WHEN p_accept THEN 'accepted' ELSE 'rejected' END, decided_by = me, decided_at = now()
    WHERE supplier_invoice_id = g.supplier_invoice_id;
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
    VALUES ('sinv_job_suggest', g.supplier_invoice_id, 'update', me, jsonb_build_object('decided', CASE WHEN p_accept THEN 'accepted' ELSE 'rejected' END, 'job', g.job_id, 'how', g.how));
    n := n + 1;
  END LOOP;
  RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public.sinv_suggestions(), public.sinv_suggest_decide(bigint[], boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sinv_suggestions(), public.sinv_suggest_decide(bigint[], boolean) TO authenticated;

-- the matcher runs with the supplier invoice attaching (each sync and after the supplier mail)
CREATE OR REPLACE FUNCTION public._sinv_autolink(p_job bigint DEFAULT NULL) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int;
BEGIN
  IF p_job IS NULL THEN BEGIN PERFORM public._po_guess_jobs(); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'po guess: %', SQLERRM; END; END IF;
  WITH sp AS (SELECT s.id, coalesce(po.job_id, g.job_id) AS job_id FROM supplier_invoices s CROSS JOIN LATERAL (SELECT public._sinv_po(s) AS po_id) x
              JOIN purchase_orders po ON po.id = x.po_id LEFT JOIN po_job_guess g ON g.po_id = po.id
              WHERE coalesce(po.job_id, g.job_id) IS NOT NULL AND (p_job IS NULL OR coalesce(po.job_id, g.job_id) = p_job)),
       ins AS (INSERT INTO supplier_invoice_customer_links (supplier_invoice_id, invoice_id, linked_by, auto)
               SELECT sp.id, i.id, NULL, true FROM sp JOIN invoices i ON i.job_id = sp.job_id AND coalesce(i.status, '') <> 'void'
               WHERE NOT EXISTS (SELECT 1 FROM supplier_invoice_customer_unlinks u WHERE u.supplier_invoice_id = sp.id AND u.invoice_id = i.id)
               ON CONFLICT DO NOTHING RETURNING 1)
  SELECT count(*) INTO n FROM ins;
  IF p_job IS NULL THEN BEGIN PERFORM public._sinv_suggest_jobs(); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'sinv suggest: %', SQLERRM; END; END IF;
  RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public._sinv_autolink(bigint) FROM PUBLIC, anon, authenticated;

DO $$ DECLARE n int; BEGIN n := public._sinv_suggest_jobs(); RAISE NOTICE 'sinv suggestions made: %', n; END $$;
NOTIFY pgrst, 'reload schema';

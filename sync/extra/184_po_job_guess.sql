-- POs from ServiceTitan with no job (about 1,860): many name the address in their summary ("106 Tall Forest", "Ellacott 556 Win…").
-- Match that address to one customer address, then to that address's job nearest the PO's date (from 45 days before to 60 days after).
-- Only when exactly one address matches. The match is kept in po_job_guess and used to attach the supplier invoices on that PO.
CREATE INDEX IF NOT EXISTS locations_street_lower ON public.locations (lower(street) text_pattern_ops);
CREATE TABLE IF NOT EXISTS public.po_job_guess (po_id bigint PRIMARY KEY REFERENCES public.purchase_orders(id) ON DELETE CASCADE, job_id bigint NOT NULL,
  location_id bigint, how text, made_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.po_job_guess ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.po_job_guess FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._po_guess_jobs() RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n int;
BEGIN
  WITH po AS (SELECT p.id, lower(coalesce(p.description, '') || ' ' || coalesce(p.notes, '')) AS t, coalesce(p.ordered_at, p.created_at) AS d
              FROM purchase_orders p WHERE p.job_id IS NULL AND coalesce(p.status, '') <> 'cancelled'
                AND coalesce(p.description, '') || coalesce(p.notes, '') ~ '\d{1,5}\s+[A-Za-z]{3,}'
                AND NOT EXISTS (SELECT 1 FROM po_job_guess g WHERE g.po_id = p.id)),
       addr AS (SELECT DISTINCT po.id, m[1] || ' ' || m[2] AS a FROM po CROSS JOIN LATERAL regexp_matches(po.t, '(?:^|[^0-9])(\d{1,5})\s+([a-z]{3,})', 'g') m
                WHERE m[2] NOT IN ('for', 'and', 'the', 'pcs', 'ton', 'btu', 'feet', 'foot', 'inch', 'tons', 'stock', 'units', 'unit', 'day', 'days', 'pack', 'box', 'boxes', 'amp', 'volt', 'gal', 'gallon')),
       loc AS (SELECT a.id, l.id AS loc_id FROM addr a JOIN locations l ON lower(l.street) LIKE a.a || '%'),
       one AS (SELECT id, min(loc_id) AS loc_id FROM loc GROUP BY id HAVING count(DISTINCT loc_id) = 1),
       pick AS (SELECT one.id, one.loc_id, (SELECT j.id FROM jobs j WHERE j.location_id = one.loc_id
                    AND coalesce(j.completed_at, j.created_at) BETWEEN po.d - interval '45 days' AND po.d + interval '60 days'
                    ORDER BY abs(extract(epoch FROM coalesce(j.completed_at, j.created_at) - po.d)) LIMIT 1) AS job_id
                FROM one JOIN po ON po.id = one.id),
       ins AS (INSERT INTO po_job_guess (po_id, job_id, location_id, how) SELECT id, job_id, loc_id, 'address on the PO' FROM pick WHERE job_id IS NOT NULL
               ON CONFLICT DO NOTHING RETURNING 1)
  SELECT count(*) INTO n FROM ins;
  RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public._po_guess_jobs() FROM PUBLIC, anon, authenticated;

-- the supplier invoice attaching now also uses the PO's matched job
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
  RETURN n;
END $f$;
REVOKE EXECUTE ON FUNCTION public._sinv_autolink(bigint) FROM PUBLIC, anon, authenticated;

DO $$ BEGIN PERFORM public._sinv_autolink(NULL); END $$;

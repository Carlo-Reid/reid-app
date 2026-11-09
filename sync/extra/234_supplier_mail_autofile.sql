-- Auto update: a supplier paper that has been read and has its PO attached goes to that supplier's list by itself
-- (no "Send to … list" press needed). One put back by hand stays on the main list until it's sent by hand again.
-- Also: the job number printed on a paper with no PO, so "Make a PO for it?" can offer that job. (Carlo, Nov 9)
-- Safe to run more than once.
ALTER TABLE public.supplier_mail ADD COLUMN IF NOT EXISTS keep_on_list boolean NOT NULL DEFAULT false;

-- send it (or p_undo: put it back on the main list, and keep it there)
CREATE OR REPLACE FUNCTION public.supplier_mail_send(p_id bigint, p_supplier text, p_undo boolean DEFAULT false) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_sup bigint;
BEGIN
  IF NOT public._can_approve_costs() THEN RAISE EXCEPTION 'You need to be able to approve costs for this'; END IF;
  IF p_undo THEN UPDATE supplier_mail SET sent_supplier_id = NULL, sent_at = NULL, sent_by = NULL, keep_on_list = true WHERE id = p_id; RETURN '{}'::jsonb; END IF;
  v_sup := public._supplier_id_of(p_supplier);
  IF v_sup IS NULL THEN RAISE EXCEPTION 'Pick the supplier first'; END IF;
  UPDATE supplier_mail SET supplier = btrim(p_supplier), sent_supplier_id = v_sup, sent_at = now(), sent_by = auth.jwt() ->> 'email', keep_on_list = false WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That document isn''t on the list any more'; END IF;
  RETURN jsonb_build_object('supplier_id', v_sup, 'supplier', (SELECT name FROM suppliers WHERE id = v_sup));
END $function$;

-- every paper that is done (read, supplier known, PO attached) goes to its supplier's list; returns the ones just sent
CREATE OR REPLACE FUNCTION public.supplier_mail_autofile() RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_out jsonb;
BEGIN
  IF NOT public._can_approve_costs() THEN RETURN '[]'::jsonb; END IF;
  WITH f AS (
    UPDATE supplier_mail m SET sent_supplier_id = public._supplier_id_of(m.supplier), sent_at = now(), sent_by = 'the app'
     WHERE m.data IS NOT NULL AND m.sent_at IS NULL AND NOT m.keep_on_list AND m.status IN ('imported', 'nothing')
       AND public._supplier_id_of(m.supplier) IS NOT NULL
       AND EXISTS (SELECT 1 FROM supplier_mail_pos x WHERE x.mail_id = m.id)
    RETURNING m.id, m.file_name, m.sent_supplier_id)
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'file', f.file_name, 'supplier', s.name) ORDER BY f.id), '[]'::jsonb) INTO v_out
    FROM f LEFT JOIN suppliers s ON s.id = f.sent_supplier_id;
  RETURN v_out;
END $function$;

-- the jobs whose number is printed on a paper (for "Make a PO for it?")
CREATE OR REPLACE FUNCTION public.supplier_mail_job_guess(p_id bigint) RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._can_approve_costs() THEN '[]'::jsonb ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object('job', j.job_number, 'customer', c.display_name) ORDER BY j.job_number)
      FROM (SELECT DISTINCT m[1] AS n FROM supplier_mail sm,
                   regexp_matches(left(concat_ws(' ', sm.subject, sm.file_name, sm.ocr_text), 100000), '(?<!\d)(\d{7,12})(?!\d)', 'g') m
             WHERE sm.id = p_id) t
      JOIN jobs j ON j.job_number::text = t.n
      LEFT JOIN customers c ON c.id = j.customer_id), '[]'::jsonb) END $f$;

REVOKE EXECUTE ON FUNCTION public.supplier_mail_send(bigint, text, boolean), public.supplier_mail_autofile(), public.supplier_mail_job_guess(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_mail_send(bigint, text, boolean), public.supplier_mail_autofile(), public.supplier_mail_job_guess(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

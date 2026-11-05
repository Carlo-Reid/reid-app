-- =====================================================================
-- Edit a ServiceTitan invoice in the app, and keep ServiceTitan's own version beside it.
--   * Press Edit on a ServiceTitan invoice (office people): it's marked edited (invoices.app_edited_at), and what
--     ServiceTitan had for it is saved in invoice_st_versions (original = as it was then).
--   * From then on the nightly sync never changes that invoice's lines or details. What ServiceTitan sends goes into
--     invoice_st_versions.st_now instead; ServiceTitan's payments still count on it, so the balance stays right.
--   * When ServiceTitan's version changes from the one you last saw (base), st_changed_at is set: the invoice shows
--     "ServiceTitan changed this", what changed, and Apply their changes / Keep mine.
-- Shape of a version: {"h": {details}, "l": {"<line id>": {line}}}. Safe to run more than once.
-- =====================================================================
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS app_edited_at timestamptz, ADD COLUMN IF NOT EXISTS app_edited_by bigint;

CREATE TABLE IF NOT EXISTS public.invoice_st_versions (
  invoice_id    bigint PRIMARY KEY REFERENCES public.invoices (id) ON DELETE CASCADE,
  original      jsonb NOT NULL,          -- ServiceTitan's invoice when it was first edited here (never changes)
  st_now        jsonb NOT NULL,          -- ServiceTitan's invoice as of the last sync
  base          jsonb NOT NULL,          -- the ServiceTitan version last applied or kept here
  st_changed_at timestamptz,             -- set when st_now differs from base (cleared by Apply / Keep mine)
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    bigint);
ALTER TABLE public.invoice_st_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.invoice_st_versions FROM anon, authenticated;

-- the details and lines that make a ServiceTitan version (the same keys the sync sends)
CREATE OR REPLACE FUNCTION public._inv_st_h(j jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $f$
  SELECT coalesce((SELECT jsonb_object_agg(k, v) FROM jsonb_each(j) e(k, v)
    WHERE k IN ('invoice_number', 'job_id', 'customer_id', 'location_id', 'business_unit_id', 'status', 'invoice_date', 'payment_terms_days',
                'po_number', 'subtotal', 'tax_total', 'total', 'amount_paid', 'sent_at')), '{}') $f$;
CREATE OR REPLACE FUNCTION public._inv_st_l(j jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $f$
  SELECT coalesce((SELECT jsonb_object_agg(k, v) FROM jsonb_each(j) e(k, v)
    WHERE k IN ('sequence', 'line_type', 'item_id', 'description', 'quantity', 'unit_price', 'unit_cost', 'taxable', 'tax_rate_pct', 'technician_id', 'st_id')), '{}') $f$;
-- what counts as ServiceTitan changing it: not payments (they still come in), not the cost it fills in; voiding it does
CREATE OR REPLACE FUNCTION public._inv_st_key(j jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $f$
  SELECT jsonb_build_object('h', coalesce(j -> 'h', '{}') - 'amount_paid' - 'status' - 'sent_at' - 'tax_total' - 'total', 'void', j -> 'h' ->> 'status' = 'void',
    'l', coalesce((SELECT jsonb_object_agg(k, jsonb_build_object('d', v -> 'description', 'q', v -> 'quantity', 'p', v -> 'unit_price', 't', v -> 'taxable', 'i', v -> 'item_id'))
                   FROM jsonb_each(coalesce(j -> 'l', '{}')) e(k, v)), '{}')) $f$;
-- the invoice as it is now, in that shape
CREATE OR REPLACE FUNCTION public._inv_st_snap(p_invoice bigint) RETURNS jsonb LANGUAGE sql STABLE SET search_path TO 'public' AS $f$
  SELECT jsonb_build_object('h', public._inv_st_h(to_jsonb(i)),
    'l', coalesce((SELECT jsonb_object_agg(l.id::text, public._inv_st_l(to_jsonb(l))) FROM invoice_lines l WHERE l.invoice_id = i.id AND l.kit_parent_line_id IS NULL), '{}'))
  FROM invoices i WHERE i.id = p_invoice $f$;

-- who may change a ServiceTitan invoice: the office
CREATE OR REPLACE FUNCTION public._inv_st_can() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT public.has_permission('invoices.adjust') OR public.current_staff_role() IN ('owner', 'admin', 'accounting', 'office') $f$;

-- press Edit on a ServiceTitan invoice: keep ServiceTitan's version, and let it be changed here
CREATE OR REPLACE FUNCTION public.inv_st_take(p_invoice bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE i invoices; v jsonb;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT * INTO i FROM invoices WHERE id = p_invoice; IF i.id IS NULL THEN RAISE EXCEPTION 'That invoice no longer exists'; END IF;
  IF i.st_id IS NULL THEN RETURN jsonb_build_object('id', i.id); END IF;   -- made in the app: edited the usual way
  IF i.store_copy_of IS NOT NULL THEN RAISE EXCEPTION 'This is the store''s copy. It''s made from the customer''s invoice.'; END IF;
  IF i.status = 'void' THEN RAISE EXCEPTION 'This invoice was voided'; END IF;
  IF NOT public._inv_st_can() THEN RAISE EXCEPTION 'Only the office can change a ServiceTitan invoice'; END IF;
  IF i.app_edited_at IS NOT NULL THEN RETURN jsonb_build_object('id', i.id); END IF;
  v := public._inv_st_snap(i.id);
  INSERT INTO invoice_st_versions (invoice_id, original, st_now, base, created_by) VALUES (i.id, v, v, v, public.current_app_user_id())
  ON CONFLICT (invoice_id) DO NOTHING;
  UPDATE invoices SET app_edited_at = now(), app_edited_by = public.current_app_user_id() WHERE id = i.id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('invoices', i.id, 'update', public.current_app_user_id(), jsonb_build_object('edited_here', i.invoice_number, 'servicetitan_version_kept', true));
  RETURN jsonb_build_object('id', i.id);
END $f$;

-- ServiceTitan changed it: take their version (Apply) or keep ours (Keep mine). Either way it stops asking until they change it again.
CREATE OR REPLACE FUNCTION public.inv_st_resolve(p_invoice bigint, p_apply boolean) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE i invoices; v invoice_st_versions; k text; x jsonb;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  IF NOT public._inv_st_can() THEN RAISE EXCEPTION 'Only the office can change a ServiceTitan invoice'; END IF;
  SELECT * INTO i FROM invoices WHERE id = p_invoice; SELECT * INTO v FROM invoice_st_versions WHERE invoice_id = p_invoice;
  IF i.id IS NULL OR v.invoice_id IS NULL THEN RAISE EXCEPTION 'There''s no ServiceTitan version kept for this invoice'; END IF;
  IF p_apply THEN
    DELETE FROM invoice_lines WHERE invoice_id = i.id AND kit_parent_line_id IS NOT NULL;
    DELETE FROM invoice_lines WHERE invoice_id = i.id;
    FOR k, x IN SELECT key, value FROM jsonb_each(coalesce(v.st_now -> 'l', '{}')) LOOP
      INSERT INTO invoice_lines (id, invoice_id, sequence, line_type, item_id, description, quantity, unit_price, unit_cost, taxable, tax_rate_pct, technician_id, st_id)
      OVERRIDING SYSTEM VALUE
      VALUES (k::bigint, i.id, (x ->> 'sequence')::int, coalesce(x ->> 'line_type', 'other'), (x ->> 'item_id')::bigint, coalesce(x ->> 'description', 'Item'),
              coalesce((x ->> 'quantity')::numeric, 1), coalesce((x ->> 'unit_price')::numeric, 0), coalesce((x ->> 'unit_cost')::numeric, 0),
              coalesce((x ->> 'taxable')::boolean, true), coalesce((x ->> 'tax_rate_pct')::numeric, 0), (x ->> 'technician_id')::bigint, coalesce((x ->> 'st_id')::bigint, k::bigint));
    END LOOP;
    UPDATE invoices SET invoice_date = coalesce((v.st_now -> 'h' ->> 'invoice_date')::date, invoice_date), po_number = v.st_now -> 'h' ->> 'po_number',
           payment_terms_days = coalesce((v.st_now -> 'h' ->> 'payment_terms_days')::int, payment_terms_days) WHERE id = i.id;
    PERFORM public.recalc_invoice(i.id);
  END IF;
  UPDATE invoice_st_versions SET base = st_now, st_changed_at = NULL WHERE invoice_id = i.id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('invoices', i.id, 'update', public.current_app_user_id(), jsonb_build_object(CASE WHEN p_apply THEN 'servicetitan_changes_applied' ELSE 'servicetitan_changes_kept_ours' END, i.invoice_number));
  RETURN CASE WHEN p_apply THEN 'applied' ELSE 'kept' END;
END $f$;

-- the note on an invoice edited here (a ServiceTitan invoice isn't "finished" again, so the note saves on its own)
CREATE OR REPLACE FUNCTION public.inv_set_notes(p_invoice bigint, p_notes text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE i invoices := public._inv_for_edit(p_invoice, false);
BEGIN
  UPDATE invoices SET notes = nullif(btrim(p_notes), '') WHERE id = i.id;
END $f$;

-- after a sync: mark the edited invoices whose ServiceTitan version changed (payments alone don't count)
CREATE OR REPLACE FUNCTION public._inv_st_mark() RETURNS int LANGUAGE sql SET search_path TO 'public' AS $f$
  WITH u AS (UPDATE invoice_st_versions SET st_changed_at = CASE WHEN public._inv_st_key(st_now) IS DISTINCT FROM public._inv_st_key(base) THEN coalesce(st_changed_at, now()) END
             WHERE (public._inv_st_key(st_now) IS DISTINCT FROM public._inv_st_key(base)) IS DISTINCT FROM (st_changed_at IS NOT NULL) RETURNING 1)
  SELECT count(*)::int FROM u $f$;

-- the editor: a ServiceTitan invoice edited here can be changed (finished or paid, it stays that way); one not yet edited can be taken
SELECT public._patch_fn('_inv_for_edit',
  $o$IF i.st_id IS NOT NULL THEN RAISE EXCEPTION 'This invoice came from ServiceTitan, so change it there'; END IF;$o$,
  $n$IF i.st_id IS NOT NULL AND i.app_edited_at IS NULL THEN RAISE EXCEPTION 'This invoice came from ServiceTitan. Press Edit this invoice first.'; END IF;
  IF i.st_id IS NOT NULL AND NOT public._inv_st_can() THEN RAISE EXCEPTION 'Only the office can change a ServiceTitan invoice'; END IF;$n$);
SELECT public._patch_fn('_inv_for_edit',
  $o$IF p_need_draft AND i.status <> 'draft' THEN$o$,
  $n$IF p_need_draft AND i.status <> 'draft' AND i.app_edited_at IS NULL THEN$n$);
SELECT public._patch_fn('inv_editor',
  $o$'can_edit', i.st_id IS NULL AND i.store_copy_of IS NULL AND public._can_invoice(i.job_id),$o$,
  $n$'can_edit', (i.st_id IS NULL OR (i.app_edited_at IS NOT NULL AND public._inv_st_can())) AND i.store_copy_of IS NULL AND public._can_invoice(i.job_id),
    'st_edit', i.st_id IS NOT NULL AND i.app_edited_at IS NOT NULL,
    'can_st_take', i.st_id IS NOT NULL AND i.app_edited_at IS NULL AND i.store_copy_of IS NULL AND i.status <> 'void' AND public._inv_st_can(),
    'st', (SELECT jsonb_build_object('original', v.original, 'now', v.st_now, 'base', v.base, 'changed_at', v.st_changed_at,
             'edited_at', i.app_edited_at, 'edited_by', public._staff_name(i.app_edited_by)) FROM invoice_st_versions v WHERE v.invoice_id = i.id),$n$);

REVOKE EXECUTE ON FUNCTION public.inv_st_take(bigint), public.inv_st_resolve(bigint, boolean), public.inv_set_notes(bigint, text), public._inv_st_can(),
  public._inv_st_mark(), public._inv_st_snap(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inv_st_take(bigint), public.inv_st_resolve(bigint, boolean), public.inv_set_notes(bigint, text), public._inv_st_can() TO authenticated;
NOTIFY pgrst, 'reload schema';

-- for lists (Owing) and the invoice: which of these were edited here, and which ServiceTitan has changed since
CREATE OR REPLACE FUNCTION public.inv_st_flags(p_ids bigint[]) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '{}'::jsonb ELSE coalesce((SELECT jsonb_object_agg(i.id, jsonb_strip_nulls(jsonb_build_object('c', v.st_changed_at)))
    FROM invoices i JOIN invoice_st_versions v ON v.invoice_id = i.id WHERE i.id = ANY (p_ids[1:2000]) AND i.app_edited_at IS NOT NULL), '{}') END $f$;
REVOKE EXECUTE ON FUNCTION public.inv_st_flags(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inv_st_flags(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

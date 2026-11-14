-- George, Nov 14, 2026: "remove 2020 payroll files and t4s and any payroll for 2020… I don't have a complete file for it".
-- Payroll starts at 2022 (George, Nov 14: 2021 too: "it is not full across the board"). Everything from 2021 or before is MOVED OUT of the payroll tables into payroll_archive (not erased:
-- George is not the admin, and a permanent delete is the admin's call). The pages in the payroll-slips storage bucket are not touched.
-- To put a row back: SELECT * FROM public.payroll_archive WHERE tbl = 'payroll_slips'; and insert it with jsonb_populate_record.
-- Runs on every update, so a 2020 slip or T4 loaded later is moved out the same way.
CREATE TABLE IF NOT EXISTS public.payroll_archive (
  id bigserial PRIMARY KEY, tbl text NOT NULL, row jsonb NOT NULL, why text NOT NULL DEFAULT 'Before 2022: payroll starts at 2022',
  archived_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.payroll_archive ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_archive FROM PUBLIC, anon, authenticated;

DO $do$
DECLARE cut date := '2022-01-01'; gone bigint[]; hit bigint[];
BEGIN
  -- people whose only payroll is from before 2022 (no log-in): they leave the list too
  SELECT coalesce(array_agg(ps.id), '{}') INTO gone FROM public.payroll_staff ps
  WHERE ps.app_user_id IS NULL
    AND (EXISTS (SELECT 1 FROM public.payroll_slips s WHERE s.staff_id = ps.id AND s.cheque_date < cut)
      OR EXISTS (SELECT 1 FROM public.payroll_t4 t WHERE t.staff_id = ps.id AND t.year < 2022)
      OR EXISTS (SELECT 1 FROM public.payroll_roe r WHERE r.staff_id = ps.id AND r.last_paid < cut))
    AND NOT EXISTS (SELECT 1 FROM public.payroll_slips s WHERE s.staff_id = ps.id AND s.cheque_date >= cut)
    AND NOT EXISTS (SELECT 1 FROM public.payroll_t4 t WHERE t.staff_id = ps.id AND t.year >= 2022)
    AND NOT EXISTS (SELECT 1 FROM public.payroll_roe r WHERE r.staff_id = ps.id AND r.last_paid >= cut)
    AND NOT EXISTS (SELECT 1 FROM public.payroll_run_lines l WHERE l.staff_id = ps.id);

  SELECT coalesce(array_agg(DISTINCT staff_id), '{}') INTO hit FROM (
    SELECT staff_id FROM public.payroll_slips WHERE cheque_date < cut
    UNION SELECT staff_id FROM public.payroll_t4 WHERE year < 2022
    UNION SELECT staff_id FROM public.payroll_roe WHERE last_paid < cut) x;

  WITH d AS (DELETE FROM public.payroll_slips WHERE cheque_date < cut RETURNING *)
    INSERT INTO public.payroll_archive (tbl, row) SELECT 'payroll_slips', to_jsonb(d) FROM d;
  WITH d AS (DELETE FROM public.payroll_t4 WHERE year < 2022 RETURNING *)
    INSERT INTO public.payroll_archive (tbl, row) SELECT 'payroll_t4', to_jsonb(d) FROM d;
  WITH d AS (DELETE FROM public.payroll_roe WHERE last_paid < cut RETURNING *)
    INSERT INTO public.payroll_archive (tbl, row) SELECT 'payroll_roe', to_jsonb(d) FROM d;
  WITH d AS (DELETE FROM public.source_remits WHERE period_from < cut RETURNING *)
    INSERT INTO public.payroll_archive (tbl, row) SELECT 'source_remits', to_jsonb(d) FROM d;
  WITH d AS (DELETE FROM public.payroll_no_slip WHERE run_date < cut RETURNING *)
    INSERT INTO public.payroll_archive (tbl, row) SELECT 'payroll_no_slip', to_jsonb(d) FROM d;
  WITH d AS (DELETE FROM public.payroll_return WHERE back_on < cut RETURNING *)
    INSERT INTO public.payroll_archive (tbl, row) SELECT 'payroll_return', to_jsonb(d) FROM d;
  WITH d AS (DELETE FROM public.payroll_gross_notes WHERE period_from < cut RETURNING *)
    INSERT INTO public.payroll_archive (tbl, row) SELECT 'payroll_gross_notes', to_jsonb(d) FROM d;

  IF cardinality(gone) > 0 THEN
    -- keep what would go with them (locked SIN, TD1, notes) in the archive too, then take them off the payroll list
    WITH d AS (DELETE FROM public.payroll_person_sin WHERE staff_id = ANY (gone) RETURNING *)
      INSERT INTO public.payroll_archive (tbl, row) SELECT 'payroll_person_sin', to_jsonb(d) FROM d;
    WITH d AS (DELETE FROM public.payroll_person_tax WHERE staff_id = ANY (gone) RETURNING *)
      INSERT INTO public.payroll_archive (tbl, row) SELECT 'payroll_person_tax', to_jsonb(d) FROM d;
    WITH d AS (DELETE FROM public.payroll_no_slip WHERE staff_id = ANY (gone) RETURNING *)
      INSERT INTO public.payroll_archive (tbl, row) SELECT 'payroll_no_slip', to_jsonb(d) FROM d;
    WITH d AS (DELETE FROM public.payroll_return WHERE staff_id = ANY (gone) RETURNING *)
      INSERT INTO public.payroll_archive (tbl, row) SELECT 'payroll_return', to_jsonb(d) FROM d;
    WITH d AS (DELETE FROM public.payroll_staff_log WHERE staff_id = ANY (gone) AND NOT auto RETURNING *)
      INSERT INTO public.payroll_archive (tbl, row) SELECT 'payroll_staff_log', to_jsonb(d) FROM d;
    WITH d AS (DELETE FROM public.payroll_staff WHERE id = ANY (gone) RETURNING *)
      INSERT INTO public.payroll_archive (tbl, row) SELECT 'payroll_staff', to_jsonb(d) FROM d;
  END IF;

  -- everyone else who lost 2020 slips: their pay history, rates and block are worked out again from what is left
  FOR i IN 1 .. coalesce(cardinality(hit), 0) LOOP
    IF NOT hit[i] = ANY (gone) THEN PERFORM public._payroll_staff_refresh(hit[i]); END IF;
  END LOOP;
END $do$;

-- From now on a 2020 (or older) pay slip, T4 or ROE is not kept when a PDF is loaded: it is skipped at the door.
CREATE OR REPLACE FUNCTION public._payroll_skip_pre2021() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  IF TG_TABLE_NAME = 'payroll_slips' THEN IF (to_jsonb(NEW)->>'cheque_date')::date < DATE '2022-01-01' THEN RETURN NULL; END IF; END IF;
  IF TG_TABLE_NAME = 'payroll_t4' THEN IF (to_jsonb(NEW)->>'year')::int < 2022 THEN RETURN NULL; END IF; END IF;
  IF TG_TABLE_NAME = 'payroll_roe' THEN IF (to_jsonb(NEW)->>'last_paid')::date < DATE '2022-01-01' THEN RETURN NULL; END IF; END IF;
  RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS trg_payroll_skip_pre2021 ON public.payroll_slips;
CREATE TRIGGER trg_payroll_skip_pre2021 BEFORE INSERT ON public.payroll_slips FOR EACH ROW EXECUTE FUNCTION public._payroll_skip_pre2021();
DROP TRIGGER IF EXISTS trg_payroll_skip_pre2021 ON public.payroll_t4;
CREATE TRIGGER trg_payroll_skip_pre2021 BEFORE INSERT ON public.payroll_t4 FOR EACH ROW EXECUTE FUNCTION public._payroll_skip_pre2021();
DROP TRIGGER IF EXISTS trg_payroll_skip_pre2021 ON public.payroll_roe;
CREATE TRIGGER trg_payroll_skip_pre2021 BEFORE INSERT ON public.payroll_roe FOR EACH ROW EXECUTE FUNCTION public._payroll_skip_pre2021();

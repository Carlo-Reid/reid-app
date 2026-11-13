-- Payroll → Source payment (George, Nov 13): before Feb 1, 2025 HSG remitted MONTHLY (the PDFs say "Regular/Quarterly -- PD7A",
-- one payment for the whole month, due the 15th of the next month); from Feb 1, 2025 twice a month (1st–15th due the 25th,
-- 16th–end due the 10th of the next month). Jan 2025 was the last whole month (paid Feb 10). The periods follow that now,
-- and payments saved earlier on half months before Feb 2025 are moved onto their whole month (this part runs on each update; it only moves what is wrong).
CREATE OR REPLACE FUNCTION public._src_monthly(d date) RETURNS boolean LANGUAGE sql IMMUTABLE AS $f$ SELECT d < date '2025-02-01' $f$;

CREATE OR REPLACE FUNCTION public._src_due(p_from date) RETURNS date LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE extract(isodow FROM d) WHEN 6 THEN d + 2 WHEN 7 THEN d + 1 ELSE d END
  FROM (SELECT CASE WHEN public._src_monthly(p_from) THEN (date_trunc('month', p_from) + interval '1 month')::date + 14
                    WHEN extract(day FROM p_from) = 1 THEN p_from + 24 ELSE (date_trunc('month', p_from) + interval '1 month')::date + 9 END AS d) s $f$;

CREATE OR REPLACE FUNCTION public._src_period_of(d date) RETURNS date[] LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN public._src_monthly(d) THEN ARRAY[date_trunc('month', d)::date, (date_trunc('month', d) + interval '1 month - 1 day')::date]
              WHEN extract(day FROM d) <= 15 THEN ARRAY[date_trunc('month', d)::date, date_trunc('month', d)::date + 14]
              ELSE ARRAY[date_trunc('month', d)::date + 15, (date_trunc('month', d) + interval '1 month - 1 day')::date] END $f$;

-- from a due date: around the 25th → the 1st–15th of that month; else the month before (whole month while monthly, else its 16th–end)
CREATE OR REPLACE FUNCTION public._src_period_of_due(d date) RETURNS date[] LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN extract(day FROM d) >= 20 AND NOT public._src_monthly(date_trunc('month', d)::date) THEN public._src_period_of(date_trunc('month', d)::date)
              ELSE public._src_period_of((date_trunc('month', d) - interval '1 day')::date) END $f$;
REVOKE EXECUTE ON FUNCTION public._src_monthly(date) FROM PUBLIC, anon, authenticated;

-- move half-month rows before Feb 2025 onto their whole month
DO $fix$
DECLARE w source_remits; tgt source_remits; f date; t date;
BEGIN
  FOR w IN SELECT * FROM source_remits WHERE public._src_monthly(period_from)
             AND NOT (extract(day FROM period_from) = 1 AND period_to = (date_trunc('month', period_from) + interval '1 month - 1 day')::date) ORDER BY period_from LOOP
    f := date_trunc('month', w.period_from)::date; t := (date_trunc('month', w.period_from) + interval '1 month - 1 day')::date;
    SELECT * INTO tgt FROM source_remits WHERE period_from = f AND period_to = t;
    IF w.pdf IS NULL AND w.total IS NULL THEN DELETE FROM source_remits WHERE id = w.id; CONTINUE; END IF;   -- an empty half month: not needed
    IF tgt.id IS NOT NULL AND tgt.pdf IS NOT NULL THEN CONTINUE; END IF;                                       -- the month already has its payment: leave it to a person
    IF tgt.id IS NOT NULL THEN DELETE FROM source_remits WHERE id = tgt.id; END IF;
    UPDATE source_remits SET period_from = f, period_to = t,
        due_date = public._src_due(f),
        note = concat_ws(' ', note, 'Moved to the whole month (monthly remitter before Feb 2025).')
      WHERE id = w.id;
  END LOOP;
END $fix$;
NOTIFY pgrst, 'reload schema';

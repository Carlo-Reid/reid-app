-- Payroll → Source payment (George, Nov 13): older paid PDFs can be added, and a PDF is always filed under its own period.
-- The period comes from the PDF: the date paid to employees (CRA counts a remittance by that date), else its due date.
-- George attached an Oct 26 payment to the Nov 1–15 card (the only card open), so the period no longer comes from the card.

-- the half month a day falls in
CREATE OR REPLACE FUNCTION public._src_period_of(d date) RETURNS date[] LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN extract(day FROM d) <= 15 THEN ARRAY[date_trunc('month', d)::date, date_trunc('month', d)::date + 14]
              ELSE ARRAY[date_trunc('month', d)::date + 15, (date_trunc('month', d) + interval '1 month - 1 day')::date] END $f$;
-- the half month a CRA due date is for: due around the 25th → 1st–15th of that month; due around the 10th → 16th–end of the month before
CREATE OR REPLACE FUNCTION public._src_period_of_due(d date) RETURNS date[] LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN extract(day FROM d) >= 20 THEN public._src_period_of(date_trunc('month', d)::date)
              ELSE public._src_period_of((date_trunc('month', d) - interval '1 day')::date) END $f$;

-- save a paid PDF on its own period (made when it is not there yet, any year). p: the PDF's fields, plus from/to of the card it was
-- dropped on (used only when the PDF has no dates).
CREATE OR REPLACE FUNCTION public.source_add_paid(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE per date[]; r source_remits;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change source payments'; END IF;
  IF nullif(p ->> 'pdf', '') IS NULL THEN RAISE EXCEPTION 'Attach the payment confirmation PDF first'; END IF;
  IF nullif(p ->> 'confirmation', '') IS NULL THEN RAISE EXCEPTION 'The confirmation number is needed'; END IF;
  IF nullif(p ->> 'paid_on', '') IS NULL OR nullif(p ->> 'paid_amount', '') IS NULL THEN RAISE EXCEPTION 'The payment date and the amount paid are needed'; END IF;
  per := CASE WHEN nullif(p ->> 'emp_paid_on', '') IS NOT NULL THEN public._src_period_of((p ->> 'emp_paid_on')::date)
              WHEN nullif(p ->> 'due', '') IS NOT NULL THEN public._src_period_of_due((p ->> 'due')::date)
              WHEN nullif(p ->> 'from', '') IS NOT NULL THEN ARRAY[(p ->> 'from')::date, (p ->> 'to')::date] END;
  IF per IS NULL THEN RAISE EXCEPTION 'I could not tell which period this payment is for (no date paid to employees and no due date on it)'; END IF;
  SELECT * INTO r FROM source_remits WHERE period_from = per[1] AND period_to = per[2];
  IF r.id IS NOT NULL AND r.confirmation IS NOT NULL AND r.pdf IS NOT NULL AND r.confirmation <> p ->> 'confirmation' THEN
    RAISE EXCEPTION 'The period % to % is already paid (confirmation %). Take that payment off first if it is wrong', per[1], per[2], r.confirmation; END IF;
  INSERT INTO source_remits (period_from, period_to, due_date) VALUES (per[1], per[2], coalesce((p ->> 'due')::date, public._src_due(per[1])))
    ON CONFLICT (period_from, period_to) DO NOTHING;
  UPDATE source_remits SET paid_on = (p ->> 'paid_on')::date, paid_amount = (p ->> 'paid_amount')::numeric, paid_how = nullif(p ->> 'paid_how', ''),
      confirmation = p ->> 'confirmation', bank_status = nullif(p ->> 'bank_status', ''), pdf = p ->> 'pdf', pdf_name = nullif(p ->> 'pdf_name', ''),
      paid_by = coalesce(nullif(p ->> 'paid_by', ''), public._staff_name(public.current_app_user_id())), paid_by_user = public.current_app_user_id(), marked_at = now(),
      due_date = coalesce((p ->> 'due')::date, due_date),
      account_no = coalesce(account_no, nullif(p ->> 'account', '')), gross = coalesce(gross, (p ->> 'gross')::numeric),
      employees = coalesce(employees, (p ->> 'employees')::int), emp_paid_on = coalesce((p ->> 'emp_paid_on')::date, emp_paid_on),
      total = coalesce(total, (p ->> 'paid_amount')::numeric)
    WHERE period_from = per[1] AND period_to = per[2] RETURNING * INTO r;
  RETURN public._src_json(r);
END $f$;
REVOKE EXECUTE ON FUNCTION public._src_period_of(date), public._src_period_of_due(date) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.source_add_paid(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.source_add_paid(jsonb) TO authenticated;

-- fix: a payment saved on a card whose period its own date paid to employees is not in moves to its own period
-- (it runs on each update; it only moves rows that are wrong, and not onto a period that already has another payment)
DO $fix$
DECLARE w source_remits; per date[]; tgt source_remits;
BEGIN
  FOR w IN SELECT * FROM source_remits WHERE pdf IS NOT NULL AND emp_paid_on IS NOT NULL AND NOT (emp_paid_on BETWEEN period_from AND period_to) LOOP
    per := public._src_period_of(w.emp_paid_on);
    SELECT * INTO tgt FROM source_remits WHERE period_from = per[1] AND period_to = per[2];
    CONTINUE WHEN tgt.id IS NOT NULL AND tgt.pdf IS NOT NULL;
    INSERT INTO source_remits (period_from, period_to, due_date) VALUES (per[1], per[2], public._src_due(per[1])) ON CONFLICT (period_from, period_to) DO NOTHING;
    UPDATE source_remits t SET paid_on = w.paid_on, paid_amount = w.paid_amount, paid_how = w.paid_how, confirmation = w.confirmation, bank_status = w.bank_status,
        pdf = w.pdf, pdf_name = w.pdf_name, paid_by = w.paid_by, paid_by_user = w.paid_by_user, marked_at = w.marked_at, emp_paid_on = w.emp_paid_on,
        account_no = coalesce(t.account_no, w.account_no),
        gross = CASE WHEN w.email_text IS NULL THEN coalesce(t.gross, w.gross) ELSE t.gross END,
        employees = CASE WHEN w.email_text IS NULL THEN coalesce(t.employees, w.employees) ELSE t.employees END,
        total = CASE WHEN w.email_text IS NULL THEN coalesce(t.total, w.total) ELSE coalesce(t.total, w.paid_amount) END,
        note = concat_ws(' ', t.note, 'Moved here from the ' || w.period_from || ' card: the payment''s date paid to employees is ' || w.emp_paid_on || '.')
      WHERE t.period_from = per[1] AND t.period_to = per[2];
    UPDATE source_remits SET paid_on = NULL, paid_amount = NULL, paid_how = NULL, confirmation = NULL, bank_status = NULL, pdf = NULL, pdf_name = NULL,
        paid_by = NULL, paid_by_user = NULL, marked_at = NULL, emp_paid_on = NULL,
        gross = CASE WHEN email_text IS NULL THEN NULL ELSE gross END, employees = CASE WHEN email_text IS NULL THEN NULL ELSE employees END,
        total = CASE WHEN email_text IS NULL THEN NULL ELSE total END
      WHERE id = w.id;
  END LOOP;
END $fix$;
NOTIFY pgrst, 'reload schema';

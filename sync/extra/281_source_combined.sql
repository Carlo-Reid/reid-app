-- A period whose source was paid together with another period's payment (George, Nov 13: Feb 2023 was paid in the March 2023 payment).
-- paid_with = the first day of the period whose payment covered it. It counts as done: not missing, no reminder, no card.
ALTER TABLE source_remits ADD COLUMN IF NOT EXISTS paid_with date;

CREATE OR REPLACE FUNCTION public._src_json(r source_remits) RETURNS jsonb LANGUAGE sql STABLE AS $f$
  SELECT jsonb_build_object('id', r.id, 'from', r.period_from, 'to', r.period_to, 'due', r.due_date, 'account', r.account_no,
    'gross', r.gross, 'total', r.total, 'employees', r.employees, 'emp_paid_on', r.emp_paid_on, 'entered_by', r.entered_by, 'entered_at', r.entered_at,
    'paid_on', r.paid_on, 'paid_amount', r.paid_amount, 'paid_how', r.paid_how, 'confirmation', r.confirmation, 'bank_status', r.bank_status,
    'paid_by', r.paid_by, 'has_pdf', r.pdf IS NOT NULL, 'pdf_name', r.pdf_name, 'marked_at', r.marked_at, 'note', r.note, 'paid_with', r.paid_with,
    'paid', (r.pdf IS NOT NULL AND r.confirmation IS NOT NULL) OR r.paid_with IS NOT NULL,
    'state', CASE WHEN r.pdf IS NOT NULL AND r.confirmation IS NOT NULL THEN (CASE WHEN r.paid_on > public._src_today() THEN 'scheduled' ELSE 'paid' END)
                  WHEN r.paid_with IS NOT NULL THEN 'combined'
                  WHEN r.due_date < public._src_today() THEN 'late' WHEN r.due_date <= public._src_today() + 3 THEN 'soon' ELSE 'due' END) $f$;

CREATE OR REPLACE FUNCTION public.source_due() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RETURN '[]'::jsonb; END IF;
  PERFORM public._src_ensure();
  RETURN coalesce((SELECT jsonb_agg(public._src_json(r) ORDER BY r.due_date) FROM source_remits r
    WHERE NOT (r.pdf IS NOT NULL AND r.confirmation IS NOT NULL) AND r.paid_with IS NULL AND r.due_date <= public._src_today() + 3), '[]'::jsonb);
END $f$;

-- mark a period as paid with another period's payment (p_with null takes the mark off)
CREATE OR REPLACE FUNCTION public.source_paid_with(p_from date, p_to date, p_with date) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE r source_remits;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change source payments'; END IF;
  INSERT INTO source_remits (period_from, period_to, due_date) VALUES (p_from, p_to, public._src_due(p_from)) ON CONFLICT (period_from, period_to) DO NOTHING;
  UPDATE source_remits SET paid_with = p_with,
    note = CASE WHEN p_with IS NULL THEN note ELSE concat_ws(' ', nullif(note, ''), 'Paid together with the payment for the period starting ' || to_char(p_with, 'Mon DD, YYYY') || '.') END
    WHERE period_from = p_from AND period_to = p_to RETURNING * INTO r;
  RETURN public._src_json(r);
END $f$;
REVOKE EXECUTE ON FUNCTION public.source_paid_with(date, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.source_paid_with(date, date, date) TO authenticated;

-- George's word: Feb 2023 was paid in the March 2023 payment (only once; left alone if it has its own PDF)
INSERT INTO source_remits (period_from, period_to, due_date, paid_with, note)
  VALUES ('2023-02-01', '2023-02-28', public._src_due('2023-02-01'), '2023-03-01', 'Paid together with the March 2023 payment (George, Nov 13, 2026).')
  ON CONFLICT (period_from, period_to) DO UPDATE SET paid_with = EXCLUDED.paid_with, note = EXCLUDED.note
  WHERE source_remits.pdf IS NULL AND source_remits.paid_with IS NULL;
NOTIFY pgrst, 'reload schema';

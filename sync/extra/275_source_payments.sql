-- Payroll → Source payments (George, Nov 13): the CRA payroll remittance (tax, CPP, EI) for each half month.
-- Periods are the 1st–15th (due the 25th) and the 16th–end (due the 10th of the next month), CRA's twice-a-month schedule;
-- a weekend due date moves to the Monday. The app makes each period by itself; the accountant's email fills the amounts
-- (pasted in), and it is Paid only once the bank's payment confirmation PDF is attached. Owners only.
-- The payroll account number is kept here in the database only (the GitHub repo is public).
CREATE TABLE IF NOT EXISTS public.source_remits (
  id bigserial PRIMARY KEY,
  period_from date NOT NULL, period_to date NOT NULL, due_date date NOT NULL,
  account_no text, gross numeric(14,2), total numeric(14,2), employees integer, emp_paid_on date,   -- from the accountant's email (or the PDF)
  email_text text, entered_by text, entered_at timestamptz,
  -- paid: from the payment confirmation PDF (all needed before it counts as paid)
  paid_on date, paid_amount numeric(14,2), paid_how text, confirmation text, bank_status text, paid_by text, paid_by_user bigint,
  pdf text, pdf_name text, marked_at timestamptz,
  note text, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (period_from, period_to));
ALTER TABLE public.source_remits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.source_remits FROM PUBLIC, anon, authenticated;

-- each person's pay rate, with the day it starts (a raise does not change the pay periods before it)
CREATE TABLE IF NOT EXISTS public.staff_pay_rates (
  id bigserial PRIMARY KEY, app_user_id bigint NOT NULL, kind text NOT NULL CHECK (kind IN ('hourly', 'salary')),
  amount numeric(12,2) NOT NULL CHECK (amount >= 0),   -- hourly: $ an hour; salary: $ a year
  starts_on date NOT NULL, set_by text, set_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (app_user_id, starts_on));
ALTER TABLE public.staff_pay_rates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.staff_pay_rates FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._src_owner() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT public.current_staff_role() IS NOT DISTINCT FROM 'owner' $f$;
CREATE OR REPLACE FUNCTION public._src_today() RETURNS date LANGUAGE sql STABLE AS $f$ SELECT (now() AT TIME ZONE 'America/Toronto')::date $f$;

-- CRA due date for a half-month period (Saturday or Sunday → the Monday after)
CREATE OR REPLACE FUNCTION public._src_due(p_from date) RETURNS date LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE extract(isodow FROM d) WHEN 6 THEN d + 2 WHEN 7 THEN d + 1 ELSE d END
  FROM (SELECT CASE WHEN extract(day FROM p_from) = 1 THEN p_from + 24 ELSE (date_trunc('month', p_from) + interval '1 month')::date + 9 END AS d) s $f$;

-- make the periods from Oct 16, 2026 up to the one we are in now (amounts come later from the accountant)
CREATE OR REPLACE FUNCTION public._src_ensure() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE d date := date '2026-10-16'; t date;
BEGIN
  WHILE d <= public._src_today() LOOP
    t := CASE WHEN extract(day FROM d) = 1 THEN d + 14 ELSE (date_trunc('month', d) + interval '1 month - 1 day')::date END;
    INSERT INTO source_remits (period_from, period_to, due_date) VALUES (d, t, public._src_due(d)) ON CONFLICT (period_from, period_to) DO NOTHING;
    d := t + 1;
  END LOOP;
END $f$;

-- one period as the page sees it (no PDF in it)
CREATE OR REPLACE FUNCTION public._src_json(r source_remits) RETURNS jsonb LANGUAGE sql STABLE AS $f$
  SELECT jsonb_build_object('id', r.id, 'from', r.period_from, 'to', r.period_to, 'due', r.due_date, 'account', r.account_no,
    'gross', r.gross, 'total', r.total, 'employees', r.employees, 'emp_paid_on', r.emp_paid_on, 'entered_by', r.entered_by, 'entered_at', r.entered_at,
    'paid_on', r.paid_on, 'paid_amount', r.paid_amount, 'paid_how', r.paid_how, 'confirmation', r.confirmation, 'bank_status', r.bank_status,
    'paid_by', r.paid_by, 'has_pdf', r.pdf IS NOT NULL, 'pdf_name', r.pdf_name, 'marked_at', r.marked_at, 'note', r.note,
    'paid', r.pdf IS NOT NULL AND r.confirmation IS NOT NULL,
    'state', CASE WHEN r.pdf IS NOT NULL AND r.confirmation IS NOT NULL THEN (CASE WHEN r.paid_on > public._src_today() THEN 'scheduled' ELSE 'paid' END)
                  WHEN r.due_date < public._src_today() THEN 'late' WHEN r.due_date <= public._src_today() + 3 THEN 'soon' ELSE 'due' END) $f$;

CREATE OR REPLACE FUNCTION public.source_list() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RETURN '[]'::jsonb; END IF;
  PERFORM public._src_ensure();
  RETURN coalesce((SELECT jsonb_agg(public._src_json(r) ORDER BY r.period_from DESC) FROM source_remits r), '[]'::jsonb);
END $f$;

-- for the reminders (Tasks and the sign-in pop-up): not paid and due within 3 days, or late
CREATE OR REPLACE FUNCTION public.source_due() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RETURN '[]'::jsonb; END IF;
  PERFORM public._src_ensure();
  RETURN coalesce((SELECT jsonb_agg(public._src_json(r) ORDER BY r.due_date) FROM source_remits r
    WHERE NOT (r.pdf IS NOT NULL AND r.confirmation IS NOT NULL) AND r.due_date <= public._src_today() + 3), '[]'::jsonb);
END $f$;

-- the accountant's numbers, read from the pasted email (the period is found or made; a due date given by the accountant wins)
CREATE OR REPLACE FUNCTION public.source_save(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE f date := (p ->> 'from')::date; t date := (p ->> 'to')::date; r source_remits;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change source payments'; END IF;
  IF f IS NULL OR t IS NULL OR t < f THEN RAISE EXCEPTION 'The remitting period was not found'; END IF;
  IF nullif(p ->> 'total', '') IS NULL THEN RAISE EXCEPTION 'The amount due was not found'; END IF;
  INSERT INTO source_remits (period_from, period_to, due_date) VALUES (f, t, coalesce((p ->> 'due')::date, public._src_due(f)))
    ON CONFLICT (period_from, period_to) DO NOTHING;
  UPDATE source_remits SET due_date = coalesce((p ->> 'due')::date, due_date), account_no = coalesce(nullif(p ->> 'account', ''), account_no),
      gross = coalesce((p ->> 'gross')::numeric, gross), total = (p ->> 'total')::numeric, employees = coalesce((p ->> 'employees')::int, employees),
      email_text = coalesce(nullif(p ->> 'email', ''), email_text), entered_by = public._staff_name(public.current_app_user_id()), entered_at = now()
    WHERE period_from = f AND period_to = t RETURNING * INTO r;
  RETURN public._src_json(r);
END $f$;

-- paid: the payment confirmation PDF is required; what was read from it is checked and saved by the person
CREATE OR REPLACE FUNCTION public.source_mark_paid(p_id bigint, p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE r source_remits;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change source payments'; END IF;
  IF nullif(p ->> 'pdf', '') IS NULL THEN RAISE EXCEPTION 'Attach the payment confirmation PDF first'; END IF;
  IF nullif(p ->> 'confirmation', '') IS NULL THEN RAISE EXCEPTION 'The confirmation number is needed'; END IF;
  IF nullif(p ->> 'paid_on', '') IS NULL OR nullif(p ->> 'paid_amount', '') IS NULL THEN RAISE EXCEPTION 'The payment date and the amount paid are needed'; END IF;
  UPDATE source_remits SET paid_on = (p ->> 'paid_on')::date, paid_amount = (p ->> 'paid_amount')::numeric, paid_how = nullif(p ->> 'paid_how', ''),
      confirmation = p ->> 'confirmation', bank_status = nullif(p ->> 'bank_status', ''), pdf = p ->> 'pdf', pdf_name = nullif(p ->> 'pdf_name', ''),
      paid_by = coalesce(nullif(p ->> 'paid_by', ''), public._staff_name(public.current_app_user_id())), paid_by_user = public.current_app_user_id(), marked_at = now(),
      account_no = coalesce(account_no, nullif(p ->> 'account', '')), gross = coalesce(gross, (p ->> 'gross')::numeric),
      employees = coalesce(employees, (p ->> 'employees')::int), emp_paid_on = coalesce((p ->> 'emp_paid_on')::date, emp_paid_on),
      total = coalesce(total, (p ->> 'total')::numeric), note = coalesce(nullif(p ->> 'note', ''), note)
    WHERE id = p_id RETURNING * INTO r;
  IF r.id IS NULL THEN RAISE EXCEPTION 'That period was not found'; END IF;
  RETURN public._src_json(r);
END $f$;

-- take a payment off (wrong PDF attached): back to not paid
CREATE OR REPLACE FUNCTION public.source_unpay(p_id bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE r source_remits;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change source payments'; END IF;
  UPDATE source_remits SET paid_on = NULL, paid_amount = NULL, paid_how = NULL, confirmation = NULL, bank_status = NULL, pdf = NULL, pdf_name = NULL,
      paid_by = NULL, paid_by_user = NULL, marked_at = NULL WHERE id = p_id RETURNING * INTO r;
  RETURN public._src_json(r);
END $f$;

CREATE OR REPLACE FUNCTION public.source_pdf(p_id bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RETURN NULL; END IF;
  RETURN (SELECT jsonb_build_object('name', pdf_name, 'pdf', pdf) FROM source_remits WHERE id = p_id);
END $f$;

-- ===== pay rates
-- the rate on a day: the newest one that started on or before it; if none was ever set, the hourly wage from ServiceTitan's staff list
CREATE OR REPLACE FUNCTION public._pay_rate_on(p_user bigint, p_day date) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(
    (SELECT jsonb_build_object('kind', kind, 'amount', amount, 'starts_on', starts_on, 'from', 'app') FROM staff_pay_rates
      WHERE app_user_id = p_user AND starts_on <= p_day ORDER BY starts_on DESC LIMIT 1),
    (SELECT jsonb_build_object('kind', 'hourly', 'amount', e.hourly_wage, 'from', 'servicetitan') FROM app_users a JOIN employees e ON e.id = a.employee_id
      WHERE a.id = p_user AND coalesce(e.hourly_wage, 0) > 0)) $f$;

CREATE OR REPLACE FUNCTION public.pay_rate_list(p_user bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('now', public._pay_rate_on(p_user, public._src_today()),
    'rates', coalesce((SELECT jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'amount', amount, 'starts_on', starts_on, 'set_by', set_by, 'set_at', set_at) ORDER BY starts_on DESC)
                       FROM staff_pay_rates WHERE app_user_id = p_user), '[]'::jsonb));
END $f$;

CREATE OR REPLACE FUNCTION public.pay_rate_set(p_user bigint, p_kind text, p_amount numeric, p_starts date) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can set pay rates'; END IF;
  IF p_kind NOT IN ('hourly', 'salary') OR p_amount IS NULL OR p_amount < 0 OR p_starts IS NULL THEN RAISE EXCEPTION 'Pick hourly or salary, the amount and the day it starts'; END IF;
  INSERT INTO staff_pay_rates (app_user_id, kind, amount, starts_on, set_by) VALUES (p_user, p_kind, p_amount, p_starts, public._staff_name(public.current_app_user_id()))
    ON CONFLICT (app_user_id, starts_on) DO UPDATE SET kind = excluded.kind, amount = excluded.amount, set_by = excluded.set_by, set_at = now();
  RETURN public.pay_rate_list(p_user);
END $f$;

CREATE OR REPLACE FUNCTION public.pay_rate_del(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can set pay rates'; END IF;
  DELETE FROM staff_pay_rates WHERE id = p_id;
END $f$;

-- the Payroll list shows the rate in force today
CREATE OR REPLACE FUNCTION public.payroll_people() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object(
      'user', a.id, 'employee', a.employee_id, 'email', a.login_email, 'role', a.role, 'active', a.active,
      'name', coalesce(nullif(concat_ws(' ', e.first_name, e.last_name), ''), a.login_email),
      'title', CASE WHEN a.role IN ('office', 'admin', 'accounting', 'dispatcher', 'warehouse') AND e.job_title ~* '^\s*technician\s*$' THEN 'Office staff' ELSE e.job_title END,
      'tech', coalesce(e.is_technician, false) AND a.role NOT IN ('office', 'admin', 'accounting', 'dispatcher', 'warehouse', 'owner'), 'wage', e.hourly_wage,
      'rate', public._pay_rate_on(a.id, public._src_today()))
      ORDER BY a.active DESC, lower(coalesce(nullif(concat_ws(' ', e.first_name, e.last_name), ''), a.login_email)))
    FROM app_users a LEFT JOIN employees e ON e.id = a.employee_id
    WHERE a.deleted_at IS NULL), '[]'::jsonb);
END $function$;

-- ===== gross pay from our timesheets, for a remittance period (a check on the accountant's Gross Payroll, not on the tax)
-- Pay days are every second Thursday from Oct 22, 2026; each pays the two weeks Monday to Sunday ending 4 days before it.
-- Techs: each day, first On the way (or arrived) to the last Done. Office staff: time in to time out, held to 15 min either side
-- of their expected hours. Hourly × hours; salary = a year ÷ 26 for each pay day. No overtime, commission, vacation pay or stats.
CREATE OR REPLACE FUNCTION public.source_gross_estimate(p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE pays date[]; pd date; wf date; wt date; people jsonb := '[]'::jsonb; u record; hrs numeric; rate jsonb; pay numeric; tot numeric := 0; missing int := 0; is_off boolean;
BEGIN
  IF NOT public._src_owner() THEN RETURN NULL; END IF;
  SELECT array_agg(d::date ORDER BY d) INTO pays FROM generate_series(p_from, p_to, interval '1 day') d WHERE ((d::date - date '2026-10-22') % 14) = 0;
  IF pays IS NULL THEN RETURN jsonb_build_object('pay_days', '[]'::jsonb, 'total', 0, 'people', '[]'::jsonb, 'missing', 0); END IF;
  FOR u IN SELECT a.id, a.role, a.employee_id, coalesce(nullif(concat_ws(' ', e.first_name, e.last_name), ''), a.login_email) AS name, coalesce(e.is_technician, false) AS tech
           FROM app_users a LEFT JOIN employees e ON e.id = a.employee_id WHERE a.deleted_at IS NULL AND a.active ORDER BY 4 LOOP
    is_off := u.role IN ('office', 'admin', 'accounting', 'dispatcher', 'warehouse');
    hrs := 0; pay := 0; rate := NULL;
    FOREACH pd IN ARRAY pays LOOP
      wf := pd - 17; wt := pd - 4;
      rate := public._pay_rate_on(u.id, wt);
      IF is_off THEN
        SELECT coalesce(sum(greatest(0, extract(epoch FROM
            least(s.time_out, CASE WHEN sc.ends IS NULL THEN s.time_out ELSE ((s.day + sc.ends) AT TIME ZONE 'America/Toronto') + interval '15 minutes' END)
          - greatest(s.time_in, CASE WHEN sc.starts IS NULL THEN s.time_in ELSE ((s.day + sc.starts) AT TIME ZONE 'America/Toronto') - interval '15 minutes' END)) / 3600)), 0)
          INTO hrs FROM office_shifts s LEFT JOIN office_schedule sc ON sc.app_user_id = s.app_user_id AND sc.weekday = extract(isodow FROM s.day)
          WHERE s.app_user_id = u.id AND s.day BETWEEN wf AND wt AND s.time_out IS NOT NULL;
      ELSIF u.tech AND u.employee_id IS NOT NULL THEN
        SELECT coalesce(sum(extract(epoch FROM (b - a)) / 3600), 0) INTO hrs FROM (
          SELECT min(coalesce(t.dispatched_on, t.arrived_on)) AS a, max(t.done_on) AS b
          FROM job_timesheets t WHERE t.technician_id = ANY (public._payroll_emp_ids(u.employee_id)) AND coalesce(t.active, true)
            AND NOT (t.canceled_on IS NOT NULL AND t.arrived_on IS NULL)
            AND (coalesce(t.arrived_on, t.dispatched_on, t.done_on) AT TIME ZONE 'America/Toronto')::date BETWEEN wf AND wt
          GROUP BY (coalesce(t.arrived_on, t.dispatched_on, t.done_on) AT TIME ZONE 'America/Toronto')::date) d WHERE b > a;
      ELSE hrs := 0;
      END IF;
      pay := pay + CASE WHEN rate IS NULL THEN 0 WHEN rate ->> 'kind' = 'salary' THEN round((rate ->> 'amount')::numeric / 26, 2) ELSE round(hrs * (rate ->> 'amount')::numeric, 2) END;
    END LOOP;
    CONTINUE WHEN rate IS NULL AND hrs = 0;   -- nobody's hours and no rate (owners, people not on payroll)
    IF rate IS NULL THEN missing := missing + 1; END IF;
    tot := tot + pay;
    people := people || jsonb_build_object('user', u.id, 'name', u.name, 'kind', CASE WHEN is_off THEN 'office' WHEN u.tech THEN 'tech' ELSE 'other' END,
      'hours', round(hrs, 2), 'rate', rate, 'pay', pay, 'no_rate', rate IS NULL);
  END LOOP;
  RETURN jsonb_build_object('pay_days', to_jsonb(pays), 'total', tot, 'people', people, 'missing', missing);
END $f$;

REVOKE EXECUTE ON FUNCTION public._src_owner(), public._src_ensure(), public._src_json(source_remits), public._pay_rate_on(bigint, date) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.source_list(), public.source_due(), public.source_save(jsonb), public.source_mark_paid(bigint, jsonb), public.source_unpay(bigint),
  public.source_pdf(bigint), public.pay_rate_list(bigint), public.pay_rate_set(bigint, text, numeric, date), public.pay_rate_del(bigint),
  public.source_gross_estimate(date, date), public.payroll_people() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.source_list(), public.source_due(), public.source_save(jsonb), public.source_mark_paid(bigint, jsonb), public.source_unpay(bigint),
  public.source_pdf(bigint), public.pay_rate_list(bigint), public.pay_rate_set(bigint, text, numeric, date), public.pay_rate_del(bigint),
  public.source_gross_estimate(date, date), public.payroll_people() TO authenticated;
NOTIFY pgrst, 'reload schema';

-- Approve for payroll, banked hours to use, and banked advances (George, Nov 15, 2026: "a tab in here for owner that allows us to approve for payroll,
-- print the entire 2 weeks or 1 week or each day… the accumulated banked hours for the tech and how many banked hours do we want to use on the payroll…
-- are we giving a banked advance to the tech that will be repaid as the weeks go on… whatever is approved will move to the payroll to print section
-- for the next pay run period and then the old pay run will be closed and only opened by carlo or george for an adjustment").
-- Owners only (rule number one: every owner, never one person's name). Safe to run more than once.

-- one line for each day an owner approved, with the hours approved for it
CREATE TABLE IF NOT EXISTS public.payroll_day_ok (
  user_id bigint NOT NULL, day date NOT NULL, hours numeric(6,2) NOT NULL CHECK (hours >= 0 AND hours <= 24),
  by_name text, at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (user_id, day));
-- for each person and pay: banked hours to use on it, and a banked advance given on it (hours paid now, repaid a set number of hours each pay after)
CREATE TABLE IF NOT EXISTS public.payroll_pay_plan (
  user_id bigint NOT NULL, pay_date date NOT NULL, bank_use numeric(8,2) NOT NULL DEFAULT 0, adv_h numeric(8,2) NOT NULL DEFAULT 0,
  adv_per_pay numeric(8,2), adv_note text, by_name text, at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (user_id, pay_date));
-- banked advances: + hours given (paid ahead), - hours repaid. What is still owed is the sum. Written by the app's pay run when it is made final.
CREATE TABLE IF NOT EXISTS public.payroll_advances (
  id bigserial PRIMARY KEY, staff_id bigint NOT NULL REFERENCES public.payroll_staff(id) ON DELETE CASCADE,
  day date NOT NULL, hours numeric(8,2) NOT NULL CHECK (hours <> 0), per_pay numeric(8,2), note text,
  run_id bigint, by_name text, at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS payroll_advances_staff ON public.payroll_advances (staff_id, day);
-- advances are kept in money (George, Nov 15: "if i loaned them the money at 20 per hour and they got a raise for 25 per hour the banked is for the 20 per hour
-- scenario so it would need to adjust itself and have a reason beside it"): amount = dollars (+ given, - paid back), rate = their rate an hour when it happened,
-- hours = amount / rate (what it was in hours that day). per_amt = dollars paid back each pay. What is owed is the dollars; its hours are worked out at today's rate.
ALTER TABLE public.payroll_advances ADD COLUMN IF NOT EXISTS amount numeric(10,2), ADD COLUMN IF NOT EXISTS rate numeric(10,2), ADD COLUMN IF NOT EXISTS per_amt numeric(10,2);
ALTER TABLE public.payroll_advances DROP CONSTRAINT IF EXISTS payroll_advances_hours_check; ALTER TABLE public.payroll_advances ALTER COLUMN hours DROP NOT NULL;
-- some staff want to be paid up to a set number of hours a week and have the rest banked (George, Nov 15): null = pay them all
ALTER TABLE public.payroll_staff ADD COLUMN IF NOT EXISTS bank_cap numeric(5,2);
ALTER TABLE public.payroll_pay_plan ADD COLUMN IF NOT EXISTS adv_amt numeric(10,2), ADD COLUMN IF NOT EXISTS adv_rate numeric(10,2), ADD COLUMN IF NOT EXISTS adv_per_amt numeric(10,2),
  ADD COLUMN IF NOT EXISTS adv_mode text, ADD COLUMN IF NOT EXISTS adv_per_mode text;
-- who reopened a closed pay run, when and why
ALTER TABLE public.payroll_runs ADD COLUMN IF NOT EXISTS log jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE public.payroll_day_ok ENABLE ROW LEVEL SECURITY; ALTER TABLE public.payroll_pay_plan ENABLE ROW LEVEL SECURITY; ALTER TABLE public.payroll_advances ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_day_ok, public.payroll_pay_plan, public.payroll_advances FROM PUBLIC, anon, authenticated;

-- the final pay run that paid this person on this pay day, if any (then the pay is closed)
CREATE OR REPLACE FUNCTION public._pay_closed_run(p_user bigint, p_pay date) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT r.id FROM payroll_runs r JOIN payroll_run_lines x ON x.run_id = r.id JOIN payroll_staff ps ON ps.id = x.staff_id
  WHERE r.status = 'final' AND r.pay_date = p_pay AND ps.app_user_id = p_user LIMIT 1 $f$;

CREATE OR REPLACE FUNCTION public._adv_owing(p_staff bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  WITH a AS (SELECT x.*, coalesce(x.amount, round(x.hours * x.rate, 2), 0) AS amt FROM payroll_advances x WHERE x.staff_id = p_staff),
       g AS (SELECT * FROM a WHERE amt > 0 ORDER BY day DESC, id DESC LIMIT 1)
  SELECT jsonb_build_object('owing', coalesce((SELECT sum(amt) FROM a), 0),
    'per_amt', (SELECT coalesce(per_amt, round(per_pay * rate, 2)) FROM g), 'given', (SELECT amt FROM g), 'given_rate', (SELECT rate FROM g),
    'given_h', (SELECT hours FROM g), 'given_day', (SELECT day FROM g), 'given_note', (SELECT note FROM g),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('day', b.day, 'amount', b.amt, 'rate', b.rate, 'hours', b.hours, 'note', b.note, 'by', b.by_name, 'after', b.after) ORDER BY b.day DESC, b.id DESC)
      FROM (SELECT a.*, sum(a.amt) OVER (ORDER BY a.day, a.id) AS after FROM a) b), '[]'::jsonb)) $f$;

-- everything the owner's Approve for payroll box needs for one person and one pay period
CREATE OR REPLACE FUNCTION public.payroll_approvals(p_user bigint, p_from date, p_to date, p_pay date) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._src_owner() THEN NULL ELSE jsonb_build_object(
    'days', coalesce((SELECT jsonb_agg(jsonb_build_object('day', d.day, 'hours', d.hours, 'by', d.by_name, 'at', d.at) ORDER BY d.day)
      FROM payroll_day_ok d WHERE d.user_id = p_user AND d.day BETWEEN p_from AND p_to), '[]'::jsonb),
    'plan', (SELECT to_jsonb(p) - 'user_id' FROM payroll_pay_plan p WHERE p.user_id = p_user AND p.pay_date = p_pay),
    'staff', (SELECT id FROM payroll_staff WHERE app_user_id = p_user),
    'bank', coalesce((SELECT sum(b.hours) FROM payroll_bank b JOIN payroll_staff ps ON ps.id = b.staff_id WHERE ps.app_user_id = p_user), 0),
    'adv', (SELECT public._adv_owing(ps.id) FROM payroll_staff ps WHERE ps.app_user_id = p_user),
    'rate', public._pay_rate_on(p_user, p_to),
    'cap', (SELECT bank_cap FROM payroll_staff WHERE app_user_id = p_user),
    'bank_rows', coalesce((SELECT jsonb_agg(jsonb_build_object('day', b.day, 'hours', b.hours, 'why', b.why, 'by', b.by_name) ORDER BY b.day DESC, b.id DESC)
      FROM (SELECT b.* FROM payroll_bank b JOIN payroll_staff ps ON ps.id = b.staff_id WHERE ps.app_user_id = p_user ORDER BY b.day DESC, b.id DESC LIMIT 8) b), '[]'::jsonb),
    'closed', public._pay_closed_run(p_user, p_pay)) END $f$;

-- approve (p_on) or take back days; p_hours goes with p_days, one for each
CREATE OR REPLACE FUNCTION public.payroll_day_approve(p_user bigint, p_pay date, p_days date[], p_hours numeric[], p_on boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE i int; who text := public._staff_name(public.current_app_user_id());
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can approve payroll'; END IF;
  IF public._pay_closed_run(p_user, p_pay) IS NOT NULL THEN RAISE EXCEPTION 'The pay of % is closed. An owner reopens it in Run payroll first.', to_char(p_pay, 'Mon DD, YYYY'); END IF;
  IF p_days IS NULL OR array_length(p_days, 1) IS NULL THEN RETURN; END IF;
  FOR i IN 1 .. array_length(p_days, 1) LOOP
    IF p_on THEN
      INSERT INTO payroll_day_ok (user_id, day, hours, by_name) VALUES (p_user, p_days[i], round(greatest(0, least(24, coalesce(p_hours[i], 0))), 2), who)
        ON CONFLICT (user_id, day) DO UPDATE SET hours = EXCLUDED.hours, by_name = EXCLUDED.by_name, at = now();
    ELSE DELETE FROM payroll_day_ok WHERE user_id = p_user AND day = p_days[i]; END IF;
  END LOOP;
END $f$;

-- banked hours to use and a banked advance for one pay
CREATE OR REPLACE FUNCTION public.payroll_plan_set(p_user bigint, p_pay date, p jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE amt numeric := greatest(0, coalesce(nullif(p ->> 'adv_amt', '')::numeric, 0)); per numeric := nullif(p ->> 'adv_per_amt', '')::numeric;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can approve payroll'; END IF;
  IF public._pay_closed_run(p_user, p_pay) IS NOT NULL THEN RAISE EXCEPTION 'The pay of % is closed. An owner reopens it in Run payroll first.', to_char(p_pay, 'Mon DD, YYYY'); END IF;
  IF amt > 0 AND coalesce(per, 0) <= 0 THEN RAISE EXCEPTION 'Say how much of the advance is paid back each pay'; END IF;
  INSERT INTO payroll_pay_plan (user_id, pay_date, bank_use, adv_h, adv_per_pay, adv_amt, adv_rate, adv_per_amt, adv_mode, adv_per_mode, adv_note, by_name)
    VALUES (p_user, p_pay, greatest(0, coalesce(nullif(p ->> 'bank_use', '')::numeric, 0)), greatest(0, coalesce(nullif(p ->> 'adv_h', '')::numeric, 0)),
      nullif(p ->> 'adv_per_pay', '')::numeric, amt, nullif(p ->> 'adv_rate', '')::numeric, per, nullif(p ->> 'adv_mode', ''), nullif(p ->> 'adv_per_mode', ''),
      nullif(btrim(p ->> 'adv_note'), ''), public._staff_name(public.current_app_user_id()))
    ON CONFLICT (user_id, pay_date) DO UPDATE SET bank_use = EXCLUDED.bank_use, adv_h = EXCLUDED.adv_h, adv_per_pay = EXCLUDED.adv_per_pay, adv_amt = EXCLUDED.adv_amt,
      adv_rate = EXCLUDED.adv_rate, adv_per_amt = EXCLUDED.adv_per_amt, adv_mode = EXCLUDED.adv_mode, adv_per_mode = EXCLUDED.adv_per_mode,
      adv_note = EXCLUDED.adv_note, by_name = EXCLUDED.by_name, at = now();
END $f$;

-- for Run payroll: each person's approved days in the period, their plan for the pay, and their advance still owed
CREATE OR REPLACE FUNCTION public.payroll_period_ok(p_from date, p_to date, p_pay date) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._src_owner() THEN NULL ELSE jsonb_build_object(
    'days', coalesce((SELECT jsonb_agg(jsonb_build_object('user', d.user_id, 'day', d.day, 'hours', d.hours)) FROM payroll_day_ok d WHERE d.day BETWEEN p_from AND p_to), '[]'::jsonb),
    'plans', coalesce((SELECT jsonb_agg(to_jsonb(p)) FROM payroll_pay_plan p WHERE p.pay_date = p_pay), '[]'::jsonb),
    'caps', coalesce((SELECT jsonb_agg(jsonb_build_object('staff', id, 'user', app_user_id, 'cap', bank_cap)) FROM payroll_staff WHERE bank_cap IS NOT NULL), '[]'::jsonb),
    'adv', coalesce((SELECT jsonb_agg(public._adv_owing(t.staff_id) || jsonb_build_object('staff', t.staff_id))
      FROM (SELECT staff_id FROM payroll_advances GROUP BY staff_id HAVING sum(coalesce(amount, round(hours * rate, 2), 0)) > 0) t), '[]'::jsonb)) END $f$;

-- the weekly limit: paid up to p_cap hours a week, the rest banked (null or 0 = pay them all)
CREATE OR REPLACE FUNCTION public.payroll_bank_cap_set(p_staff bigint, p_cap numeric) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change this'; END IF;
  IF p_cap IS NOT NULL AND (p_cap < 0 OR p_cap > 80) THEN RAISE EXCEPTION 'Type the hours a week, 1 to 80'; END IF;
  UPDATE payroll_staff SET bank_cap = nullif(round(p_cap, 2), 0) WHERE id = p_staff;
END $f$;

-- what a person sees about their own bank and advance on their payroll page (George, Nov 15: "only thing that should show for the tech is total banked
-- hours… and if they are given an advance it should also show up"). Themselves or an owner.
CREATE OR REPLACE FUNCTION public.payroll_my_bank(p_user bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT (public._src_owner() OR p_user = public.current_app_user_id()) THEN NULL ELSE (
    SELECT jsonb_build_object('bank', coalesce((SELECT sum(hours) FROM payroll_bank WHERE staff_id = ps.id), 0), 'cap', ps.bank_cap,
      'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('day', b.day, 'hours', b.hours, 'why', b.why) ORDER BY b.day DESC, b.id DESC)
        FROM (SELECT * FROM payroll_bank WHERE staff_id = ps.id ORDER BY day DESC, id DESC LIMIT 6) b), '[]'::jsonb),
      'adv', public._adv_owing(ps.id), 'rate', public._pay_rate_on(p_user, current_date))
    FROM payroll_staff ps WHERE ps.app_user_id = p_user) END $f$;

-- reopen a closed (final) pay run for an adjustment: owners only, with a reason; it is written on the run
CREATE OR REPLACE FUNCTION public.payroll_run_reopen(p_id bigint, p_why text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only an owner can reopen a closed pay run'; END IF;
  IF nullif(btrim(p_why), '') IS NULL THEN RAISE EXCEPTION 'Say why it is reopened'; END IF;
  UPDATE payroll_runs SET log = log || jsonb_build_array(jsonb_build_object('what', 'reopened', 'why', btrim(p_why), 'by', public._staff_name(public.current_app_user_id()), 'at', now()))
    WHERE id = p_id;
  PERFORM public.payroll_run_undo(p_id);
END $f$;

-- the app's pay run, in money: l.adv_pay (dollars given now), l.adv_back (dollars paid back on this pay), l.adv_rate (their rate an hour on this pay),
-- l.adv_per_amt (dollars paid back each pay after)
CREATE OR REPLACE FUNCTION public._payroll_adv_slip() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE l jsonb; g numeric; r numeric; rt numeric;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.run_id IS NOT NULL THEN DELETE FROM payroll_advances WHERE run_id = OLD.run_id AND staff_id = OLD.staff_id; END IF;
    RETURN OLD;
  END IF;
  IF NEW.run_id IS NULL THEN RETURN NEW; END IF;
  SELECT x.l INTO l FROM payroll_run_lines x WHERE x.run_id = NEW.run_id AND x.staff_id = NEW.staff_id;
  g := nullif(l ->> 'adv_pay', '')::numeric; r := nullif(l ->> 'adv_back', '')::numeric; rt := nullif(nullif(l ->> 'adv_rate', '')::numeric, 0);
  DELETE FROM payroll_advances WHERE run_id = NEW.run_id AND staff_id = NEW.staff_id;
  IF coalesce(g, 0) > 0 THEN INSERT INTO payroll_advances (staff_id, day, amount, rate, hours, per_amt, note, run_id, by_name)
    VALUES (NEW.staff_id, NEW.cheque_date, round(g, 2), rt, round(g / rt, 2), nullif(l ->> 'adv_per_amt', '')::numeric,
      coalesce(nullif(l ->> 'adv_note', ''), 'Banked advance on the pay of ' || to_char(NEW.cheque_date, 'Mon DD, YYYY')), NEW.run_id, NEW.loaded_by); END IF;
  IF coalesce(r, 0) > 0 THEN INSERT INTO payroll_advances (staff_id, day, amount, rate, hours, note, run_id, by_name)
    VALUES (NEW.staff_id, NEW.cheque_date, -round(r, 2), rt, -round(r / rt, 2), 'Paid back on the pay of ' || to_char(NEW.cheque_date, 'Mon DD, YYYY'), NEW.run_id, NEW.loaded_by); END IF;
  RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS trg_payroll_adv_slip ON public.payroll_slips;
CREATE TRIGGER trg_payroll_adv_slip AFTER INSERT OR DELETE ON public.payroll_slips FOR EACH ROW EXECUTE FUNCTION public._payroll_adv_slip();

REVOKE EXECUTE ON FUNCTION public._payroll_adv_slip(), public._pay_closed_run(bigint, date), public._adv_owing(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_bank_cap_set(bigint, numeric), public.payroll_my_bank(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_bank_cap_set(bigint, numeric), public.payroll_my_bank(bigint) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_approvals(bigint, date, date, date), public.payroll_day_approve(bigint, date, date[], numeric[], boolean),
  public.payroll_plan_set(bigint, date, jsonb), public.payroll_period_ok(date, date, date), public.payroll_run_reopen(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_approvals(bigint, date, date, date), public.payroll_day_approve(bigint, date, date[], numeric[], boolean),
  public.payroll_plan_set(bigint, date, jsonb), public.payroll_period_ok(date, date, date), public.payroll_run_reopen(bigint, text) TO authenticated;

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
-- who reopened a closed pay run, when and why
ALTER TABLE public.payroll_runs ADD COLUMN IF NOT EXISTS log jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE public.payroll_day_ok ENABLE ROW LEVEL SECURITY; ALTER TABLE public.payroll_pay_plan ENABLE ROW LEVEL SECURITY; ALTER TABLE public.payroll_advances ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_day_ok, public.payroll_pay_plan, public.payroll_advances FROM PUBLIC, anon, authenticated;

-- the final pay run that paid this person on this pay day, if any (then the pay is closed)
CREATE OR REPLACE FUNCTION public._pay_closed_run(p_user bigint, p_pay date) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT r.id FROM payroll_runs r JOIN payroll_run_lines x ON x.run_id = r.id JOIN payroll_staff ps ON ps.id = x.staff_id
  WHERE r.status = 'final' AND r.pay_date = p_pay AND ps.app_user_id = p_user LIMIT 1 $f$;

CREATE OR REPLACE FUNCTION public._adv_owing(p_staff bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT jsonb_build_object('owing', coalesce((SELECT sum(hours) FROM payroll_advances WHERE staff_id = p_staff), 0),
    'per_pay', (SELECT per_pay FROM payroll_advances WHERE staff_id = p_staff AND hours > 0 ORDER BY day DESC, id DESC LIMIT 1),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('day', a.day, 'hours', a.hours, 'note', a.note, 'by', a.by_name, 'after', a.after) ORDER BY a.day DESC, a.id DESC)
      FROM (SELECT x.*, sum(x.hours) OVER (ORDER BY x.day, x.id) AS after FROM payroll_advances x WHERE x.staff_id = p_staff) a), '[]'::jsonb)) $f$;

-- everything the owner's Approve for payroll box needs for one person and one pay period
CREATE OR REPLACE FUNCTION public.payroll_approvals(p_user bigint, p_from date, p_to date, p_pay date) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._src_owner() THEN NULL ELSE jsonb_build_object(
    'days', coalesce((SELECT jsonb_agg(jsonb_build_object('day', d.day, 'hours', d.hours, 'by', d.by_name, 'at', d.at) ORDER BY d.day)
      FROM payroll_day_ok d WHERE d.user_id = p_user AND d.day BETWEEN p_from AND p_to), '[]'::jsonb),
    'plan', (SELECT to_jsonb(p) - 'user_id' FROM payroll_pay_plan p WHERE p.user_id = p_user AND p.pay_date = p_pay),
    'staff', (SELECT id FROM payroll_staff WHERE app_user_id = p_user),
    'bank', coalesce((SELECT sum(b.hours) FROM payroll_bank b JOIN payroll_staff ps ON ps.id = b.staff_id WHERE ps.app_user_id = p_user), 0),
    'adv', (SELECT public._adv_owing(ps.id) FROM payroll_staff ps WHERE ps.app_user_id = p_user),
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
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can approve payroll'; END IF;
  IF public._pay_closed_run(p_user, p_pay) IS NOT NULL THEN RAISE EXCEPTION 'The pay of % is closed. An owner reopens it in Run payroll first.', to_char(p_pay, 'Mon DD, YYYY'); END IF;
  IF coalesce(nullif(p ->> 'adv_h', '')::numeric, 0) > 0 AND coalesce(nullif(p ->> 'adv_per_pay', '')::numeric, 0) <= 0 THEN
    RAISE EXCEPTION 'Say how many hours of the advance are paid back each pay'; END IF;
  INSERT INTO payroll_pay_plan (user_id, pay_date, bank_use, adv_h, adv_per_pay, adv_note, by_name)
    VALUES (p_user, p_pay, greatest(0, coalesce(nullif(p ->> 'bank_use', '')::numeric, 0)), greatest(0, coalesce(nullif(p ->> 'adv_h', '')::numeric, 0)),
      nullif(p ->> 'adv_per_pay', '')::numeric, nullif(btrim(p ->> 'adv_note'), ''), public._staff_name(public.current_app_user_id()))
    ON CONFLICT (user_id, pay_date) DO UPDATE SET bank_use = EXCLUDED.bank_use, adv_h = EXCLUDED.adv_h, adv_per_pay = EXCLUDED.adv_per_pay,
      adv_note = EXCLUDED.adv_note, by_name = EXCLUDED.by_name, at = now();
END $f$;

-- for Run payroll: each person's approved days in the period, their plan for the pay, and their advance still owed
CREATE OR REPLACE FUNCTION public.payroll_period_ok(p_from date, p_to date, p_pay date) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._src_owner() THEN NULL ELSE jsonb_build_object(
    'days', coalesce((SELECT jsonb_agg(jsonb_build_object('user', d.user_id, 'day', d.day, 'hours', d.hours)) FROM payroll_day_ok d WHERE d.day BETWEEN p_from AND p_to), '[]'::jsonb),
    'plans', coalesce((SELECT jsonb_agg(to_jsonb(p)) FROM payroll_pay_plan p WHERE p.pay_date = p_pay), '[]'::jsonb),
    'adv', coalesce((SELECT jsonb_agg(jsonb_build_object('staff', t.staff_id, 'owing', t.o, 'per_pay',
        (SELECT per_pay FROM payroll_advances a WHERE a.staff_id = t.staff_id AND a.hours > 0 ORDER BY a.day DESC, a.id DESC LIMIT 1)))
      FROM (SELECT staff_id, sum(hours) o FROM payroll_advances GROUP BY staff_id HAVING sum(hours) > 0) t), '[]'::jsonb)) END $f$;

-- reopen a closed (final) pay run for an adjustment: owners only, with a reason; it is written on the run
CREATE OR REPLACE FUNCTION public.payroll_run_reopen(p_id bigint, p_why text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only an owner can reopen a closed pay run'; END IF;
  IF nullif(btrim(p_why), '') IS NULL THEN RAISE EXCEPTION 'Say why it is reopened'; END IF;
  UPDATE payroll_runs SET log = log || jsonb_build_array(jsonb_build_object('what', 'reopened', 'why', btrim(p_why), 'by', public._staff_name(public.current_app_user_id()), 'at', now()))
    WHERE id = p_id;
  PERFORM public.payroll_run_undo(p_id);
END $f$;

-- the app's pay run: l.adv_h (advance given, paid now) and l.adv_rep (advance hours paid back on this pay) on the line
CREATE OR REPLACE FUNCTION public._payroll_adv_slip() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE l jsonb; g numeric; r numeric;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.run_id IS NOT NULL THEN DELETE FROM payroll_advances WHERE run_id = OLD.run_id AND staff_id = OLD.staff_id; END IF;
    RETURN OLD;
  END IF;
  IF NEW.run_id IS NULL THEN RETURN NEW; END IF;
  SELECT x.l INTO l FROM payroll_run_lines x WHERE x.run_id = NEW.run_id AND x.staff_id = NEW.staff_id;
  g := nullif(l ->> 'adv_h', '')::numeric; r := nullif(l ->> 'adv_rep', '')::numeric;
  DELETE FROM payroll_advances WHERE run_id = NEW.run_id AND staff_id = NEW.staff_id;
  IF coalesce(g, 0) > 0 THEN INSERT INTO payroll_advances (staff_id, day, hours, per_pay, note, run_id, by_name)
    VALUES (NEW.staff_id, NEW.cheque_date, round(g, 2), nullif(l ->> 'adv_per_pay', '')::numeric, coalesce(nullif(l ->> 'adv_note', ''), 'Banked advance on the pay of ' || to_char(NEW.cheque_date, 'Mon DD, YYYY')), NEW.run_id, NEW.loaded_by); END IF;
  IF coalesce(r, 0) > 0 THEN INSERT INTO payroll_advances (staff_id, day, hours, note, run_id, by_name)
    VALUES (NEW.staff_id, NEW.cheque_date, -round(r, 2), 'Paid back on the pay of ' || to_char(NEW.cheque_date, 'Mon DD, YYYY'), NEW.run_id, NEW.loaded_by); END IF;
  RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS trg_payroll_adv_slip ON public.payroll_slips;
CREATE TRIGGER trg_payroll_adv_slip AFTER INSERT OR DELETE ON public.payroll_slips FOR EACH ROW EXECUTE FUNCTION public._payroll_adv_slip();

REVOKE EXECUTE ON FUNCTION public._payroll_adv_slip(), public._pay_closed_run(bigint, date), public._adv_owing(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_approvals(bigint, date, date, date), public.payroll_day_approve(bigint, date, date[], numeric[], boolean),
  public.payroll_plan_set(bigint, date, jsonb), public.payroll_period_ok(date, date, date), public.payroll_run_reopen(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_approvals(bigint, date, date, date), public.payroll_day_approve(bigint, date, date[], numeric[], boolean),
  public.payroll_plan_set(bigint, date, jsonb), public.payroll_period_ok(date, date, date), public.payroll_run_reopen(bigint, text) TO authenticated;

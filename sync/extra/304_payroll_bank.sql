-- Banked hours (George, Nov 14, 2026: "we bank hours for employees so is there a way to show a banked total and it carries forward and when used it is updated").
-- One line for each change to a person's bank: + hours put in, - hours used. The balance is the sum, so it carries forward by itself.
-- A line is never deleted by hand: a mistake is fixed with a line the other way. The lines made by an app pay run come and go with its pay slip
-- (made final, Fix this person, Undo final), by a trigger on payroll_slips. Owners only.
CREATE TABLE IF NOT EXISTS public.payroll_bank (
  id bigserial PRIMARY KEY, staff_id bigint NOT NULL REFERENCES public.payroll_staff(id) ON DELETE CASCADE,
  day date NOT NULL, hours numeric(8,2) NOT NULL CHECK (hours <> 0), why text NOT NULL,
  run_id bigint, by_name text, at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS payroll_bank_staff ON public.payroll_bank (staff_id, day);
ALTER TABLE public.payroll_bank ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_bank FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.payroll_bank_list(p_staff bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._src_owner() THEN NULL ELSE jsonb_build_object(
    'balance', coalesce((SELECT sum(hours) FROM payroll_bank WHERE staff_id = p_staff), 0),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('id', b.id, 'day', b.day, 'hours', b.hours, 'why', b.why, 'run', b.run_id, 'by', b.by_name, 'after', b.after)
        ORDER BY b.day DESC, b.id DESC) FROM (SELECT x.*, sum(x.hours) OVER (ORDER BY x.day, x.id) AS after FROM payroll_bank x WHERE x.staff_id = p_staff) b), '[]'::jsonb)) END $f$;

CREATE OR REPLACE FUNCTION public.payroll_bank_balances() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._src_owner() THEN NULL ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('staff', ps.id, 'user', ps.app_user_id, 'hours', t.h))
    FROM (SELECT staff_id, sum(hours) h FROM payroll_bank GROUP BY staff_id) t JOIN payroll_staff ps ON ps.id = t.staff_id), '[]'::jsonb) END $f$;

-- p_hours: + put in the bank, - used (paid out or taken as time off)
CREATE OR REPLACE FUNCTION public.payroll_bank_add(p_staff bigint, p_day date, p_hours numeric, p_why text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change banked hours'; END IF;
  IF p_staff IS NULL OR NOT EXISTS (SELECT 1 FROM payroll_staff WHERE id = p_staff) THEN RAISE EXCEPTION 'That person is not on payroll'; END IF;
  IF coalesce(p_hours, 0) = 0 THEN RAISE EXCEPTION 'Type the hours'; END IF;
  IF nullif(trim(p_why), '') IS NULL THEN RAISE EXCEPTION 'Say why'; END IF;
  INSERT INTO payroll_bank (staff_id, day, hours, why, by_name) VALUES (p_staff, coalesce(p_day, current_date), round(p_hours, 2), trim(p_why), public._staff_name(public.current_app_user_id()));
  RETURN public.payroll_bank_list(p_staff);
END $f$;

-- the app's pay run: l.bank_used (hours paid out of the bank) and l.bank_add (hours put in: overtime banked at 1.5) on the line
CREATE OR REPLACE FUNCTION public._payroll_bank_slip() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE l jsonb; u numeric; a numeric; pd date;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.run_id IS NOT NULL THEN DELETE FROM payroll_bank WHERE run_id = OLD.run_id AND staff_id = OLD.staff_id; END IF;
    RETURN OLD;
  END IF;
  IF NEW.run_id IS NULL THEN RETURN NEW; END IF;
  SELECT x.l INTO l FROM payroll_run_lines x WHERE x.run_id = NEW.run_id AND x.staff_id = NEW.staff_id;
  u := nullif(l ->> 'bank_used', '')::numeric; a := nullif(l ->> 'bank_add', '')::numeric; pd := NEW.cheque_date;
  DELETE FROM payroll_bank WHERE run_id = NEW.run_id AND staff_id = NEW.staff_id;
  IF coalesce(u, 0) > 0 THEN INSERT INTO payroll_bank (staff_id, day, hours, why, run_id, by_name)
    VALUES (NEW.staff_id, pd, -round(u, 2), 'Paid out on the pay of ' || to_char(pd, 'Mon DD, YYYY'), NEW.run_id, NEW.loaded_by); END IF;
  IF coalesce(a, 0) > 0 THEN INSERT INTO payroll_bank (staff_id, day, hours, why, run_id, by_name)
    VALUES (NEW.staff_id, pd, round(a, 2), 'Overtime banked on the pay of ' || to_char(pd, 'Mon DD, YYYY') || ' (' || (round(a / 1.5, 2))::text || ' h × 1.5)', NEW.run_id, NEW.loaded_by); END IF;
  RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS trg_payroll_bank_slip ON public.payroll_slips;
CREATE TRIGGER trg_payroll_bank_slip AFTER INSERT OR DELETE ON public.payroll_slips FOR EACH ROW EXECUTE FUNCTION public._payroll_bank_slip();

REVOKE EXECUTE ON FUNCTION public._payroll_bank_slip() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_bank_list(bigint), public.payroll_bank_balances(), public.payroll_bank_add(bigint, date, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_bank_list(bigint), public.payroll_bank_balances(), public.payroll_bank_add(bigint, date, numeric, text) TO authenticated;

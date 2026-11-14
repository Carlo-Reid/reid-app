-- Payroll, round 2 of the pay run (George, Nov 14): the company's numbers filled in, each person's SIN kept locked (encrypted) in their file,
-- the tax numbers of each year kept in the database (so a new year is added without a change to the app's code), and the time a tech was
-- paid for against the time on jobs (to see pay that was not for job work). Owners only. Safe to run more than once.

-- 1. The company's numbers: filled in where they are empty (the payroll account number is typed in the app by an owner, never here)
UPDATE public.company_settings SET payroll_employer = jsonb_build_object(
    'legal_name', 'Home Service Group Inc.', 'address', '36 Capital Drive', 'city', 'Ottawa', 'prov', 'ON', 'postal', 'K2G 0E9',
    'contact', 'George Monsour', 'contact2', 'Carlo Magliocchetti') || coalesce(payroll_employer, '{}'::jsonb)
  WHERE true;

-- 2. SINs, locked. The number is encrypted with a key kept in the Supabase vault (created here the first time); the table only holds the
-- locked number and its last 3 digits. Opening one (to see it, or to put it in a T4 or ROE file) is written in payroll_sin_opened.
CREATE TABLE IF NOT EXISTS public.payroll_person_sin (
  staff_id bigint PRIMARY KEY REFERENCES public.payroll_staff(id) ON DELETE CASCADE,
  sin_enc bytea NOT NULL, last3 text NOT NULL, from_where text, set_by text, set_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.payroll_sin_opened (id bigserial PRIMARY KEY, staff_id bigint, why text, by_name text, at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.payroll_person_sin ENABLE ROW LEVEL SECURITY; ALTER TABLE public.payroll_sin_opened ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_person_sin, public.payroll_sin_opened FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._sin_key() RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE k text;
BEGIN
  SELECT decrypted_secret INTO k FROM vault.decrypted_secrets WHERE name = 'payroll_sin_key' LIMIT 1;
  IF k IS NULL THEN
    k := encode(extensions.gen_random_bytes(32), 'hex');
    PERFORM vault.create_secret(k, 'payroll_sin_key', 'Locks the SINs in payroll (do not delete: the SINs can not be opened without it)');
  END IF;
  RETURN k;
END $f$;
REVOKE EXECUTE ON FUNCTION public._sin_key() FROM PUBLIC, anon, authenticated;
SELECT public._sin_key();   -- make the key now, so it exists before the first SIN

CREATE OR REPLACE FUNCTION public._sin_ok(s text) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE t int := 0; d int;
BEGIN
  IF s !~ '^[0-9]{9}$' OR s = '000000000' THEN RETURN false; END IF;
  FOR i IN 1..9 LOOP d := substr(s, i, 1)::int * CASE WHEN i % 2 = 0 THEN 2 ELSE 1 END; IF d > 9 THEN d := d - 9; END IF; t := t + d; END LOOP;
  RETURN t % 10 = 0;
END $f$;

-- save a SIN (p_only_new: keep the one on file if there is one, for SINs read from a T4)
CREATE OR REPLACE FUNCTION public.payroll_sin_set(p_staff bigint, p_user bigint, p_name text, p_sin text, p_from text, p_only_new boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE sid bigint; s text := regexp_replace(coalesce(p_sin, ''), '\D', '', 'g'); who text := public._staff_name(public.current_app_user_id());
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF NOT public._sin_ok(s) THEN RAISE EXCEPTION 'That is not a good SIN: it is 9 digits and must pass the check digit'; END IF;
  sid := public._payroll_staff_for(p_staff, p_user, p_name, NULL);
  IF p_only_new AND EXISTS (SELECT 1 FROM payroll_person_sin WHERE staff_id = sid) THEN RETURN jsonb_build_object('staff', sid, 'kept', true); END IF;
  INSERT INTO payroll_person_sin (staff_id, sin_enc, last3, from_where, set_by) VALUES (sid, extensions.pgp_sym_encrypt(s, public._sin_key()), right(s, 3), p_from, who)
    ON CONFLICT (staff_id) DO UPDATE SET sin_enc = excluded.sin_enc, last3 = excluded.last3, from_where = excluded.from_where, set_by = excluded.set_by, set_at = now();
  RETURN jsonb_build_object('staff', sid, 'last3', right(s, 3));
END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_sin_set(bigint, bigint, text, text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_sin_set(bigint, bigint, text, text, text, boolean) TO authenticated;

-- what is on file, locked: the last 3 digits only, for everyone (no number is opened)
CREATE OR REPLACE FUNCTION public.payroll_sin_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._src_owner() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('staff', x.staff_id, 'user', ps.app_user_id,
      'last3', x.last3, 'from', x.from_where, 'by', x.set_by, 'at', x.set_at,
      'opened', (SELECT jsonb_build_object('by', o.by_name, 'at', o.at, 'why', o.why) FROM payroll_sin_opened o WHERE o.staff_id = x.staff_id ORDER BY o.id DESC LIMIT 1)))
    FROM payroll_person_sin x JOIN payroll_staff ps ON ps.id = x.staff_id), '[]'::jsonb) END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_sin_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_sin_list() TO authenticated;

-- open SINs (to see one, or to make a T4 / ROE file): each one opened is written down with who and why
CREATE OR REPLACE FUNCTION public.payroll_sin_open(p_staff bigint[], p_why text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE who text := public._staff_name(public.current_app_user_id()); r jsonb;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('staff', x.staff_id, 'sin', extensions.pgp_sym_decrypt(x.sin_enc, public._sin_key()))), '[]'::jsonb) INTO r
    FROM payroll_person_sin x WHERE x.staff_id = ANY (p_staff);
  INSERT INTO payroll_sin_opened (staff_id, why, by_name) SELECT x.staff_id, left(coalesce(p_why, ''), 200), who FROM payroll_person_sin x WHERE x.staff_id = ANY (p_staff);
  RETURN r;
END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_sin_open(bigint[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_sin_open(bigint[], text) TO authenticated;

CREATE OR REPLACE FUNCTION public.payroll_sin_del(p_staff bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  DELETE FROM payroll_person_sin WHERE staff_id = p_staff;
END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_sin_del(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_sin_del(bigint) TO authenticated;

-- 3. The tax numbers of each year (the CRA's T4127), kept here so a new year can be added in the app: {"2027": {cpp: {...}, ei: {...}, fed: {...}, on: {...}}}
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS payroll_tax jsonb NOT NULL DEFAULT '{}'::jsonb;
CREATE OR REPLACE FUNCTION public.payroll_tax_tables() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._src_owner() THEN (SELECT payroll_tax FROM company_settings LIMIT 1) ELSE '{}'::jsonb END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_tax_tables() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_tax_tables() TO authenticated;
CREATE OR REPLACE FUNCTION public.payroll_tax_year_set(p_year int, p jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF p_year < 2024 OR p_year > 2100 THEN RAISE EXCEPTION 'Pick a year'; END IF;
  UPDATE company_settings SET payroll_tax = CASE WHEN p IS NULL THEN payroll_tax - p_year::text
    ELSE payroll_tax || jsonb_build_object(p_year::text, p || jsonb_build_object('set_by', public._staff_name(public.current_app_user_id()), 'set_at', now())) END WHERE true;
END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_tax_year_set(int, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_tax_year_set(int, jsonb) TO authenticated;

-- 4. The time each pay slip paid for, against the time on jobs in that pay period (techs: from their job timesheets in the app).
-- day = first "on the way" to last "done"; job = on the way to done on each call (the drive and the work), held to the day;
-- events = the grey events on their schedule (meetings, shop time, off sick…) in the period, by name.
CREATE OR REPLACE FUNCTION public.payroll_job_time(p_from date) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  WITH sl AS (
    SELECT s.id, s.staff_id, ps.app_user_id, s.cheque_date, coalesce(s.period_from, s.cheque_date - 17) pf, coalesce(s.period_to, s.cheque_date - 4) pt,
           a.employee_id e, public._slip_parts(s.earn, s.adj, s.dfg) pp
    FROM payroll_slips s JOIN payroll_staff ps ON ps.id = s.staff_id JOIN app_users a ON a.id = ps.app_user_id
    WHERE s.cheque_date >= p_from AND a.employee_id IS NOT NULL),
  ids AS (SELECT DISTINCT sl.e, unnest(public._payroll_emp_ids(sl.e)) tid FROM sl),
  ts AS (SELECT ids.e, (coalesce(t.arrived_on, t.dispatched_on, t.done_on) AT TIME ZONE 'America/Toronto')::date d,
                coalesce(t.dispatched_on, t.arrived_on) a, t.done_on b
         FROM job_timesheets t JOIN ids ON ids.tid = t.technician_id
         WHERE coalesce(t.active, true) AND t.done_on IS NOT NULL AND coalesce(t.dispatched_on, t.arrived_on) IS NOT NULL
           AND t.done_on > coalesce(t.dispatched_on, t.arrived_on) AND t.done_on - coalesce(t.dispatched_on, t.arrived_on) < interval '16 hours'
           AND (coalesce(t.arrived_on, t.dispatched_on, t.done_on) AT TIME ZONE 'America/Toronto')::date >= p_from - 20),
  dd AS (SELECT e, d, extract(epoch FROM max(b) - min(a)) / 3600 span,
                least(extract(epoch FROM sum(b - a)) / 3600, extract(epoch FROM max(b) - min(a)) / 3600) job FROM ts GROUP BY 1, 2),
  ev AS (SELECT ids.e, (n.starts_at AT TIME ZONE 'America/Toronto')::date d, coalesce(nullif(btrim(n.name), ''), 'Event') nm,
                CASE WHEN n.all_day THEN 8 ELSE least(coalesce(n.duration_min, 0), 600) / 60.0 END h
         FROM st_nonjob_appts n JOIN ids ON n.technician_id = ids.tid OR n.technician_id = (SELECT st_id FROM employees WHERE id = ids.tid)
         WHERE coalesce(n.active, true) AND n.name !~* 'call past' AND (n.starts_at AT TIME ZONE 'America/Toronto')::date >= p_from - 20)
  SELECT CASE WHEN NOT public._src_owner() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('slip', sl.id, 'staff', sl.staff_id, 'user', sl.app_user_id,
      'cheque', sl.cheque_date, 'm', to_char(sl.cheque_date, 'YYYY-MM'), 'paid_h', coalesce((sl.pp ->> 'hours')::numeric, 0),
      'hourly', coalesce((sl.pp ->> 'hourly')::numeric, 0) + coalesce((sl.pp ->> 'ot')::numeric, 0), 'days', x.days, 'span', round(coalesce(x.span, 0)::numeric, 2), 'job', round(coalesce(x.job, 0)::numeric, 2),
      'ev', round(coalesce(y.h, 0)::numeric, 2), 'evn', coalesce(y.n, '{}'::jsonb)))
    FROM sl
    LEFT JOIN LATERAL (SELECT count(*) days, sum(span) span, sum(job) job FROM dd WHERE dd.e = sl.e AND dd.d BETWEEN sl.pf AND sl.pt) x ON true
    LEFT JOIN LATERAL (SELECT sum(h) h, jsonb_object_agg(nm, hh) n FROM (SELECT nm, round(sum(h)::numeric, 2) hh, sum(h) h FROM ev WHERE ev.e = sl.e AND ev.d BETWEEN sl.pf AND sl.pt GROUP BY nm) q) y ON true), '[]'::jsonb) END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_job_time(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_job_time(date) TO authenticated;

-- Payroll from the accountant's pay slips (George, Nov 13): "I will send a pdf of all the paycheques from the past to align all the info in
-- payroll". The slips are read in the browser (Payroll → Source/Private → Load a payroll PDF), checked by an owner, then saved here.
-- payroll_staff = everyone on payroll: app users (app_user_id) and people with no log-in (owners' family, store greeters, past staff).
-- Pay amounts are kept here only, never in the repo (it is public). Owners only. Family support (FRO) lines are never kept.
CREATE TABLE IF NOT EXISTS public.payroll_staff (
  id bigserial PRIMARY KEY, app_user_id bigint UNIQUE, name text NOT NULL, aliases text[] NOT NULL DEFAULT '{}',
  block text CHECK (block IN ('owner', 'tech', 'sales', 'office', 'greeter', 'past')),   -- null = worked out from the role
  pay_kind text, rate numeric(12,2), per_pay numeric(12,2), reg_hours numeric(6,2), vac_pct numeric(5,2), on_call numeric(10,2), ot_rate numeric(10,2),
  benefits boolean, vehicle boolean, wsib_rate numeric(6,3), started_on date, left_on date, notes text,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.payroll_slips (
  id bigserial PRIMARY KEY, staff_id bigint NOT NULL REFERENCES public.payroll_staff(id) ON DELETE CASCADE,
  cheque_date date NOT NULL, period_from date, period_to date, slip_name text,
  kind text, rate numeric(12,2), per_pay numeric(12,2), reg_hours numeric(6,2), hours numeric(6,2),
  gross numeric(12,2), net numeric(12,2), commission numeric(12,2), vac numeric(12,2), vac_pct numeric(5,2), on_call numeric(10,2), ot_rate numeric(10,2), ot_pay numeric(12,2),
  cpp numeric(12,2), ei numeric(12,2), tax numeric(12,2), benefits boolean, vehicle boolean,
  earn jsonb, dfg jsonb, adj jsonb, file_name text, loaded_by text, loaded_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (staff_id, cheque_date));
CREATE TABLE IF NOT EXISTS public.payroll_staff_log (
  id bigserial PRIMARY KEY, staff_id bigint NOT NULL REFERENCES public.payroll_staff(id) ON DELETE CASCADE,
  day date, note text NOT NULL, auto boolean NOT NULL DEFAULT false, by_name text, at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.payroll_staff ENABLE ROW LEVEL SECURITY; ALTER TABLE public.payroll_slips ENABLE ROW LEVEL SECURITY; ALTER TABLE public.payroll_staff_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_staff, public.payroll_slips, public.payroll_staff_log FROM PUBLIC, anon, authenticated;
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS payroll_wsib jsonb NOT NULL DEFAULT '{}'::jsonb;   -- WSIB $ per $100 of pay, by block

-- the block a person goes in: their own pick, else from the role; Past when they left, are turned off, or had no pay for 3 months
CREATE OR REPLACE FUNCTION public._payroll_block(p_role text, p_title text, p_tech boolean, p_active boolean, ps public.payroll_staff, p_last date)
RETURNS text LANGUAGE sql STABLE AS $f$
  SELECT CASE WHEN ps.left_on IS NOT NULL OR ps.block = 'past' THEN 'past'
              WHEN ps.block IS NOT NULL THEN ps.block
              WHEN p_role = 'owner' THEN 'owner'
              WHEN p_active IS FALSE THEN 'past'
              WHEN p_last IS NOT NULL AND p_last < public._src_today() - 92 THEN 'past'
              WHEN p_role ILIKE 'sales%' OR p_title ILIKE '%sales%' THEN 'sales'
              WHEN p_tech THEN 'tech'
              ELSE 'office' END $f$;

-- the Payroll list: app users and people on payroll only. Owners only.
CREATE OR REPLACE FUNCTION public.payroll_people() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF public.current_staff_role() IS DISTINCT FROM 'owner' THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x ->> 'sortname') FROM (
    SELECT jsonb_build_object(
      'user', a.id, 'staff', ps.id, 'employee', a.employee_id, 'email', a.login_email, 'role', a.role, 'active', a.active,
      'name', coalesce(nullif(concat_ws(' ', e.first_name, e.last_name), ''), a.login_email),
      'sortname', lower(coalesce(nullif(concat_ws(' ', e.first_name, e.last_name), ''), a.login_email)),
      'aliases', to_jsonb(coalesce(ps.aliases, '{}')),
      'title', CASE WHEN a.role IN ('office', 'admin', 'accounting', 'dispatcher', 'warehouse') AND e.job_title ~* '^\s*technician\s*$' THEN 'Office staff' ELSE e.job_title END,
      'tech', coalesce(e.is_technician, false) AND a.role NOT IN ('office', 'admin', 'accounting', 'dispatcher', 'warehouse', 'owner'), 'wage', e.hourly_wage,
      'rate', public._pay_rate_on(a.id, public._src_today()),
      'pay_kind', ps.pay_kind, 'last_pay', l.last_pay, 'first_pay', l.first_pay, 'slips', coalesce(l.n, 0),
      'block', public._payroll_block(a.role, e.job_title, coalesce(e.is_technician, false) AND a.role NOT IN ('office', 'admin', 'accounting', 'dispatcher', 'warehouse', 'owner'), a.active, ps, l.last_pay),
      'block_set', ps.block IS NOT NULL OR ps.left_on IS NOT NULL) AS x
    FROM app_users a LEFT JOIN employees e ON e.id = a.employee_id LEFT JOIN payroll_staff ps ON ps.app_user_id = a.id
      LEFT JOIN LATERAL (SELECT max(s.cheque_date) AS last_pay, min(s.cheque_date) AS first_pay, count(*) AS n FROM payroll_slips s WHERE s.staff_id = ps.id) l ON true
    WHERE a.deleted_at IS NULL
    UNION ALL
    SELECT jsonb_build_object('user', NULL, 'staff', ps.id, 'role', NULL, 'active', ps.left_on IS NULL, 'name', ps.name, 'sortname', lower(ps.name),
      'aliases', to_jsonb(ps.aliases), 'title', NULL, 'tech', false,
      'rate', CASE WHEN ps.pay_kind = 'salary' THEN jsonb_build_object('kind', 'salary', 'amount', ps.rate) WHEN ps.rate IS NOT NULL THEN jsonb_build_object('kind', 'hourly', 'amount', ps.rate) END,
      'pay_kind', ps.pay_kind, 'last_pay', l.last_pay, 'first_pay', l.first_pay, 'slips', coalesce(l.n, 0),
      'block', public._payroll_block(NULL, NULL, false, NULL, ps, l.last_pay), 'block_set', ps.block IS NOT NULL OR ps.left_on IS NOT NULL)
    FROM payroll_staff ps LEFT JOIN LATERAL (SELECT max(s.cheque_date) AS last_pay, min(s.cheque_date) AS first_pay, count(*) AS n FROM payroll_slips s WHERE s.staff_id = ps.id) l ON true
    WHERE ps.app_user_id IS NULL) q), '[]'::jsonb);
END $function$;

-- slips already on file for these cheque dates (to warn when a slip loaded again has other amounts)
CREATE OR REPLACE FUNCTION public.payroll_slips_on_file(p_cheques date[]) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._src_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('staff', s.staff_id, 'user', ps.app_user_id, 'cheque', s.cheque_date, 'gross', s.gross, 'net', s.net, 'file', s.file_name))
    FROM payroll_slips s JOIN payroll_staff ps ON ps.id = s.staff_id WHERE s.cheque_date = ANY (p_cheques)), '[]'::jsonb) ELSE '[]'::jsonb END $f$;

-- after slips change: the person's details from their newest slip, the pay history notes, and (app users) their pay rates from the slips
CREATE OR REPLACE FUNCTION public._payroll_staff_refresh(p_staff bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE ps payroll_staff; s record; p_kind text; p_rate numeric; p_per numeric; first boolean := true; amt numeric; k text;
BEGIN
  SELECT * INTO ps FROM payroll_staff WHERE id = p_staff; IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO s FROM payroll_slips WHERE staff_id = p_staff ORDER BY cheque_date DESC LIMIT 1;
  IF FOUND THEN
    UPDATE payroll_staff SET pay_kind = s.kind, rate = s.rate, per_pay = s.per_pay, reg_hours = s.reg_hours, vac_pct = s.vac_pct, on_call = nullif(s.on_call, 0),
      ot_rate = s.ot_rate, benefits = s.benefits, vehicle = s.vehicle, updated_at = now() WHERE id = p_staff;
  END IF;
  DELETE FROM payroll_staff_log WHERE staff_id = p_staff AND auto;
  IF ps.app_user_id IS NOT NULL THEN DELETE FROM staff_pay_rates WHERE app_user_id = ps.app_user_id AND set_by = 'Payroll PDF'; END IF;
  FOR s IN SELECT * FROM payroll_slips WHERE staff_id = p_staff ORDER BY cheque_date LOOP
    IF first THEN
      INSERT INTO payroll_staff_log (staff_id, day, note, auto) VALUES (p_staff, s.cheque_date, 'First pay on file: cheque of ' || to_char(s.cheque_date, 'Mon DD, YYYY')
        || CASE WHEN s.kind = 'salary' THEN ', salary ' || to_char(s.per_pay, 'FM$999,990.00') || ' a pay'
                WHEN s.rate IS NOT NULL THEN ', ' || to_char(s.rate, 'FM$990.00') || ' an hour' ELSE ', commission only' END || '.', true);
    ELSIF p_kind IS DISTINCT FROM s.kind OR p_rate IS DISTINCT FROM s.rate THEN
      INSERT INTO payroll_staff_log (staff_id, day, note, auto) VALUES (p_staff, s.cheque_date,
        CASE WHEN p_rate IS NOT NULL AND s.rate IS NOT NULL AND p_kind IS NOT DISTINCT FROM s.kind AND s.rate > p_rate THEN 'Raise: '
             WHEN p_rate IS NOT NULL AND s.rate IS NOT NULL AND p_kind IS NOT DISTINCT FROM s.kind THEN 'Pay went down: ' ELSE 'Pay changed: ' END
        || coalesce(CASE WHEN p_kind = 'salary' THEN to_char(p_per, 'FM$999,990.00') || ' a pay' ELSE to_char(p_rate, 'FM$990.00') || ' an hour' END, 'commission only')
        || ' → ' || coalesce(CASE WHEN s.kind = 'salary' THEN to_char(s.per_pay, 'FM$999,990.00') || ' a pay' ELSE to_char(s.rate, 'FM$990.00') || ' an hour' END, 'commission only')
        || ' (pay period from ' || to_char(coalesce(s.period_from, s.cheque_date), 'Mon DD, YYYY') || ').', true);
    END IF;
    IF ps.app_user_id IS NOT NULL AND s.rate IS NOT NULL AND (first OR p_rate IS DISTINCT FROM s.rate OR p_kind IS DISTINCT FROM s.kind) THEN
      k := CASE WHEN s.kind = 'salary' THEN 'salary' ELSE 'hourly' END; amt := s.rate;
      INSERT INTO staff_pay_rates (app_user_id, kind, amount, starts_on, set_by) VALUES (ps.app_user_id, k, amt, coalesce(s.period_from, s.cheque_date), 'Payroll PDF')
        ON CONFLICT (app_user_id, starts_on) DO NOTHING;
    END IF;
    first := false; p_kind := s.kind; p_rate := s.rate; p_per := s.per_pay;
  END LOOP;
END $f$;

-- save the slips an owner checked. p = { file, slips: [{ staff, user, name, block, new, slip fields… }] }
CREATE OR REPLACE FUNCTION public.payroll_slips_save(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE x jsonb; sid bigint; touched bigint[] := '{}'; n int := 0; who text := public._staff_name(public.current_app_user_id()); nm text;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can load payroll'; END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p -> 'slips', '[]'::jsonb)) LOOP
    nm := btrim(x ->> 'name'); sid := nullif(x ->> 'staff', '')::bigint;
    IF sid IS NULL AND nullif(x ->> 'user', '') IS NOT NULL THEN
      SELECT id INTO sid FROM payroll_staff WHERE app_user_id = (x ->> 'user')::bigint;
      IF sid IS NULL THEN
        INSERT INTO payroll_staff (app_user_id, name) VALUES ((x ->> 'user')::bigint, nm) RETURNING id INTO sid;
      END IF;
    END IF;
    IF sid IS NULL THEN
      SELECT id INTO sid FROM payroll_staff WHERE app_user_id IS NULL AND (lower(name) = lower(nm) OR lower(nm) = ANY (SELECT lower(a) FROM unnest(aliases) a)) LIMIT 1;
      IF sid IS NULL THEN INSERT INTO payroll_staff (name, block) VALUES (nm, nullif(x ->> 'block', '')) RETURNING id INTO sid; END IF;
    END IF;
    UPDATE payroll_staff SET aliases = CASE WHEN lower(nm) = ANY (SELECT lower(a) FROM unnest(aliases) a) OR lower(name) = lower(nm) THEN aliases ELSE aliases || nm END,
      block = CASE WHEN nullif(x ->> 'block', '') IS NOT NULL AND (x ->> 'block_set')::boolean THEN x ->> 'block' ELSE block END
      WHERE id = sid;
    INSERT INTO payroll_slips (staff_id, cheque_date, period_from, period_to, slip_name, kind, rate, per_pay, reg_hours, hours, gross, net, commission, vac, vac_pct,
        on_call, ot_rate, ot_pay, cpp, ei, tax, benefits, vehicle, earn, dfg, adj, file_name, loaded_by)
      VALUES (sid, (x ->> 'cheque')::date, (x ->> 'from')::date, (x ->> 'to')::date, nm, x ->> 'kind', (x ->> 'rate')::numeric, (x ->> 'per_pay')::numeric,
        (x ->> 'reg_hours')::numeric, (x ->> 'hours')::numeric, (x ->> 'gross')::numeric, (x ->> 'net')::numeric, (x ->> 'commission')::numeric, (x ->> 'vac')::numeric,
        (x ->> 'vac_pct')::numeric, (x ->> 'on_call')::numeric, (x ->> 'ot_rate')::numeric, (x ->> 'ot_pay')::numeric, (x ->> 'cpp')::numeric, (x ->> 'ei')::numeric,
        (x ->> 'tax_inc')::numeric, (x ->> 'benefits')::boolean, (x ->> 'vehicle')::boolean, x -> 'earn', x -> 'dfg', x -> 'adj', p ->> 'file', who)
      ON CONFLICT (staff_id, cheque_date) DO UPDATE SET period_from = EXCLUDED.period_from, period_to = EXCLUDED.period_to, slip_name = EXCLUDED.slip_name,
        kind = EXCLUDED.kind, rate = EXCLUDED.rate, per_pay = EXCLUDED.per_pay, reg_hours = EXCLUDED.reg_hours, hours = EXCLUDED.hours, gross = EXCLUDED.gross,
        net = EXCLUDED.net, commission = EXCLUDED.commission, vac = EXCLUDED.vac, vac_pct = EXCLUDED.vac_pct, on_call = EXCLUDED.on_call, ot_rate = EXCLUDED.ot_rate,
        ot_pay = EXCLUDED.ot_pay, cpp = EXCLUDED.cpp, ei = EXCLUDED.ei, tax = EXCLUDED.tax, benefits = EXCLUDED.benefits, vehicle = EXCLUDED.vehicle,
        earn = EXCLUDED.earn, dfg = EXCLUDED.dfg, adj = EXCLUDED.adj, file_name = EXCLUDED.file_name, loaded_by = EXCLUDED.loaded_by, loaded_at = now();
    n := n + 1; IF NOT sid = ANY (touched) THEN touched := touched || sid; END IF;
  END LOOP;
  FOREACH sid IN ARRAY touched LOOP PERFORM public._payroll_staff_refresh(sid); END LOOP;
  RETURN jsonb_build_object('saved', n, 'people', cardinality(touched));
END $f$;

-- an owner's changes to a person's payroll details (or a new person with no log-in). p = { staff | user, name, block, wsib_rate, left_on, started_on, notes }
CREATE OR REPLACE FUNCTION public.payroll_staff_set(p jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE sid bigint := nullif(p ->> 'staff', '')::bigint; u bigint := nullif(p ->> 'user', '')::bigint; who text := public._staff_name(public.current_app_user_id());
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  IF sid IS NULL AND u IS NOT NULL THEN SELECT id INTO sid FROM payroll_staff WHERE app_user_id = u; END IF;
  IF sid IS NULL THEN
    IF u IS NULL AND nullif(btrim(p ->> 'name'), '') IS NULL THEN RAISE EXCEPTION 'A name is needed'; END IF;
    INSERT INTO payroll_staff (app_user_id, name) VALUES (u, coalesce(nullif(btrim(p ->> 'name'), ''), (SELECT concat_ws(' ', e.first_name, e.last_name) FROM app_users a LEFT JOIN employees e ON e.id = a.employee_id WHERE a.id = u), 'Staff'))
      RETURNING id INTO sid;
  END IF;
  UPDATE payroll_staff SET
    name = CASE WHEN p ? 'name' AND nullif(btrim(p ->> 'name'), '') IS NOT NULL THEN btrim(p ->> 'name') ELSE name END,
    block = CASE WHEN p ? 'block' THEN nullif(p ->> 'block', '') ELSE block END,
    wsib_rate = CASE WHEN p ? 'wsib_rate' THEN nullif(p ->> 'wsib_rate', '')::numeric ELSE wsib_rate END,
    left_on = CASE WHEN p ? 'left_on' THEN nullif(p ->> 'left_on', '')::date ELSE left_on END,
    started_on = CASE WHEN p ? 'started_on' THEN nullif(p ->> 'started_on', '')::date ELSE started_on END,
    notes = CASE WHEN p ? 'notes' THEN nullif(p ->> 'notes', '') ELSE notes END, updated_at = now()
    WHERE id = sid;
  IF nullif(btrim(p ->> 'log'), '') IS NOT NULL THEN
    INSERT INTO payroll_staff_log (staff_id, day, note, by_name) VALUES (sid, public._src_today(), btrim(p ->> 'log'), who);
  END IF;
  RETURN sid;
END $f$;

CREATE OR REPLACE FUNCTION public.payroll_wsib() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._src_owner() THEN coalesce((SELECT s.payroll_wsib FROM company_settings s ORDER BY s.id LIMIT 1), '{}'::jsonb) ELSE '{}'::jsonb END $f$;
CREATE OR REPLACE FUNCTION public.payroll_wsib_set(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  UPDATE company_settings SET payroll_wsib = coalesce(p, '{}'::jsonb) WHERE id = (SELECT id FROM company_settings ORDER BY id LIMIT 1);
  RETURN public.payroll_wsib();
END $f$;

-- the private part of a person's payroll page: details, pay history, and what they cost us and brought in (this year, and the last 12 months)
-- Company's own share of source: CPP the same as the employee's, EI 1.4 times. WSIB: their rate (else their block's) × pay ÷ 100.
-- Brought in: techs, our invoices (before HST) on the jobs they worked, split between the techs on the job; sales, the jobs they sold.
CREATE OR REPLACE FUNCTION public.payroll_person_private(p_user bigint, p_staff bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off' AS $f$
DECLARE ps payroll_staff; a record; emp bigint; ids bigint[]; blk text; wsib numeric; y0 date := date_trunc('year', public._src_today())::date; m12 date := public._src_today() - 365;
  per jsonb := '[]'::jsonb; lo date; hi date; lab text; g numeric; cpp numeric; ei numeric; tx numeric; n int; inn numeric;
BEGIN
  IF NOT public._src_owner() THEN RETURN NULL; END IF;
  IF p_staff IS NOT NULL THEN SELECT * INTO ps FROM payroll_staff WHERE id = p_staff; ELSE SELECT * INTO ps FROM payroll_staff WHERE app_user_id = p_user; END IF;
  SELECT au.id, au.role, au.active, au.employee_id, e.job_title, coalesce(e.is_technician, false) AND au.role NOT IN ('office', 'admin', 'accounting', 'dispatcher', 'warehouse', 'owner') AS tech
    INTO a FROM app_users au LEFT JOIN employees e ON e.id = au.employee_id WHERE au.id = coalesce(p_user, ps.app_user_id);
  emp := a.employee_id; ids := CASE WHEN emp IS NULL THEN '{}'::bigint[] ELSE public._payroll_emp_ids(emp) END;
  blk := public._payroll_block(a.role, a.job_title, coalesce(a.tech, false), a.active, ps, (SELECT max(cheque_date) FROM payroll_slips WHERE staff_id = ps.id));
  wsib := coalesce(ps.wsib_rate, nullif((SELECT s.payroll_wsib ->> blk FROM company_settings s ORDER BY s.id LIMIT 1), '')::numeric);
  FOR lab, lo, hi IN VALUES ('ytd', y0, public._src_today()), ('m12', m12, public._src_today()) LOOP
    SELECT sum(z.gross), sum(z.cpp), sum(z.ei), sum(z.tax), count(*) INTO g, cpp, ei, tx, n FROM payroll_slips z WHERE z.staff_id = ps.id AND z.cheque_date BETWEEN lo AND hi;
    inn := NULL;
    IF blk = 'tech' AND cardinality(ids) > 0 THEN
      SELECT sum(i.subtotal / greatest(1, (SELECT count(DISTINCT t2.technician_id) FROM job_timesheets t2 WHERE t2.job_id = i.job_id AND coalesce(t2.active, true) AND t2.arrived_on IS NOT NULL)))
        INTO inn FROM invoices i
        WHERE i.status NOT IN ('void', 'draft') AND i.store_copy_of IS NULL AND i.invoice_date BETWEEN lo AND hi
          AND EXISTS (SELECT 1 FROM job_timesheets t WHERE t.job_id = i.job_id AND t.technician_id = ANY (ids) AND coalesce(t.active, true) AND t.arrived_on IS NOT NULL);
    ELSIF blk = 'sales' AND cardinality(ids) > 0 THEN
      SELECT sum(i.subtotal) INTO inn FROM invoices i JOIN jobs j ON j.id = i.job_id
        WHERE i.status NOT IN ('void', 'draft') AND i.store_copy_of IS NULL AND i.invoice_date BETWEEN lo AND hi
          AND coalesce(j.sold_by_employee_id, (SELECT e.sold_by_employee_id FROM estimates e WHERE e.id = j.sold_estimate_id)) = ANY (ids);
    END IF;
    per := per || jsonb_build_object('k', lab, 'from', lo, 'to', hi, 'slips', n, 'gross', g, 'cpp', cpp, 'ei', ei, 'tax', tx,
      'co_cpp', cpp, 'co_ei', round(ei * 1.4, 2), 'source', round(coalesce(tx, 0) + 2 * coalesce(cpp, 0) + 2.4 * coalesce(ei, 0), 2),
      'wsib', CASE WHEN wsib IS NOT NULL AND g IS NOT NULL THEN round(g * wsib / 100, 2) END,
      'cost', CASE WHEN g IS NOT NULL THEN round(g + coalesce(cpp, 0) + 1.4 * coalesce(ei, 0) + coalesce(g * wsib / 100, 0), 2) END,
      'brought_in', round(inn, 2));
  END LOOP;
  RETURN jsonb_build_object('staff', CASE WHEN ps.id IS NOT NULL THEN to_jsonb(ps) END, 'block', blk, 'wsib', wsib, 'wsib_own', ps.wsib_rate IS NOT NULL,
    'started', (SELECT started_on FROM staff_started WHERE app_user_id = a.id),
    'periods', per,
    'slips', coalesce((SELECT jsonb_agg(jsonb_build_object('cheque', s.cheque_date, 'from', s.period_from, 'to', s.period_to, 'kind', s.kind, 'rate', s.rate, 'per_pay', s.per_pay,
        'hours', s.reg_hours, 'gross', s.gross, 'net', s.net, 'commission', s.commission, 'vac', s.vac, 'on_call', s.on_call, 'ot_pay', s.ot_pay, 'cpp', s.cpp, 'ei', s.ei, 'tax', s.tax,
        'earn', s.earn, 'dfg', s.dfg, 'adj', s.adj) ORDER BY s.cheque_date DESC) FROM payroll_slips s WHERE s.staff_id = ps.id), '[]'::jsonb),
    'log', coalesce((SELECT jsonb_agg(jsonb_build_object('day', l.day, 'note', l.note, 'auto', l.auto, 'by', l.by_name) ORDER BY l.day DESC NULLS LAST, l.id DESC)
        FROM payroll_staff_log l WHERE l.staff_id = ps.id), '[]'::jsonb));
END $f$;

-- the gross for each month from the pay slips (by cheque date), for the Source payment's month table when the accountant's email has no gross
CREATE OR REPLACE FUNCTION public.source_summary() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off' AS $f$
DECLARE f date; t date;
BEGIN
  IF NOT public._src_owner() THEN RETURN NULL; END IF;
  SELECT (date_trunc('year', min(period_from)) - interval '1 year')::date INTO f FROM source_remits WHERE pdf IS NOT NULL OR total IS NOT NULL;
  IF f IS NULL THEN RETURN '[]'::jsonb; END IF;
  t := (date_trunc('month', public._src_today()) + interval '1 month - 1 day')::date;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('m', to_char(m, 'YYYY-MM'), 'source', s.source, 'gross', coalesce(ps.gross, s.gross), 'gross_from', CASE WHEN ps.gross IS NOT NULL THEN 'slips' WHEN s.gross IS NOT NULL THEN 'email' END,
      'n', coalesce(s.n, 0), 'sales', v.sales) ORDER BY m)
    FROM generate_series(f, t, interval '1 month') m
    LEFT JOIN LATERAL (SELECT sum(coalesce(r.paid_amount, r.total)) FILTER (WHERE r.pdf IS NOT NULL) AS source, sum(r.gross) AS gross,
                              count(*) FILTER (WHERE r.pdf IS NOT NULL) AS n
                         FROM source_remits r WHERE r.period_from >= m::date AND r.period_from < (m + interval '1 month')::date) s ON true
    LEFT JOIN LATERAL (SELECT sum(x.gross) AS gross FROM payroll_slips x WHERE x.cheque_date >= m::date AND x.cheque_date < (m + interval '1 month')::date) ps ON true
    LEFT JOIN LATERAL (SELECT sum(i.subtotal) AS sales FROM invoices i
                        WHERE i.status NOT IN ('void', 'draft') AND NOT coalesce(i.paid_at_store, false) AND i.store_copy_of IS NULL
                          AND i.invoice_date >= m::date AND i.invoice_date < (m + interval '1 month')::date) v ON true), '[]'::jsonb);
END $f$;

REVOKE EXECUTE ON FUNCTION public._payroll_block(text, text, boolean, boolean, public.payroll_staff, date), public._payroll_staff_refresh(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_people(), public.payroll_slips_on_file(date[]), public.payroll_slips_save(jsonb), public.payroll_staff_set(jsonb),
  public.payroll_wsib(), public.payroll_wsib_set(jsonb), public.payroll_person_private(bigint, bigint), public.source_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_people(), public.payroll_slips_on_file(date[]), public.payroll_slips_save(jsonb), public.payroll_staff_set(jsonb),
  public.payroll_wsib(), public.payroll_wsib_set(jsonb), public.payroll_person_private(bigint, bigint), public.source_summary() TO authenticated;
NOTIFY pgrst, 'reload schema';

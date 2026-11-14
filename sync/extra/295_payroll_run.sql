-- Payroll run in the app (George, Nov 14: "go ahead with the not built yet": the app works out the pay, the tax, CPP and EI, prints the cheques
-- and stubs, and makes the T4 and ROE files). Owners only. The deductions are worked out in the browser by the CRA T4127 formulas (Ontario);
-- this file keeps each person's TD1 numbers, the pay runs and their lines, and the employer's numbers for the cheques and the files.
-- Never stored: a SIN or a bank account number (cheques are printed on the bank's pre-printed cheques, which already carry the account line).
-- Safe to run more than once.

CREATE TABLE IF NOT EXISTS public.payroll_person_tax (
  staff_id bigint PRIMARY KEY REFERENCES public.payroll_staff(id) ON DELETE CASCADE,
  td1_fed numeric(12,2), td1_on numeric(12,2), extra_tax numeric(10,2) NOT NULL DEFAULT 0, deps int NOT NULL DEFAULT 0,
  cpp_exempt boolean NOT NULL DEFAULT false, ei_exempt boolean NOT NULL DEFAULT false,
  ben_per_pay numeric(10,2), other_ded jsonb NOT NULL DEFAULT '[]'::jsonb, vac_pct numeric(5,2),
  updated_by text, updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.payroll_runs (
  id bigserial PRIMARY KEY, pay_date date NOT NULL, period_from date, period_to date,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'final', 'void')), note text,
  made_by text, made_at timestamptz NOT NULL DEFAULT now(), final_by text, final_at timestamptz);
CREATE TABLE IF NOT EXISTS public.payroll_run_lines (
  id bigserial PRIMARY KEY, run_id bigint NOT NULL REFERENCES public.payroll_runs(id) ON DELETE CASCADE,
  staff_id bigint NOT NULL REFERENCES public.payroll_staff(id) ON DELETE CASCADE,
  name text, block text, l jsonb NOT NULL DEFAULT '{}'::jsonb, cheque_no int, printed_at timestamptz,
  UNIQUE (run_id, staff_id));
ALTER TABLE public.payroll_slips ADD COLUMN IF NOT EXISTS run_id bigint;
ALTER TABLE public.payroll_person_tax ENABLE ROW LEVEL SECURITY; ALTER TABLE public.payroll_runs ENABLE ROW LEVEL SECURITY; ALTER TABLE public.payroll_run_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_person_tax, public.payroll_runs, public.payroll_run_lines FROM PUBLIC, anon, authenticated;
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS payroll_employer jsonb NOT NULL DEFAULT '{}'::jsonb;

-- everything the pay run page needs for one pay day: each person's TD1 numbers, what they were paid so far this year (before this pay),
-- what their newest pay slip had (vacation %, benefits taken off, hours, salary), the employer's numbers, and the pay runs
CREATE OR REPLACE FUNCTION public.payroll_run_info(p_pay date) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._src_owner() THEN NULL ELSE jsonb_build_object(
    'staff', coalesce((SELECT jsonb_agg(jsonb_build_object('staff', ps.id, 'user', ps.app_user_id, 'name', ps.name,
        'tax', (SELECT to_jsonb(t) - 'staff_id' FROM payroll_person_tax t WHERE t.staff_id = ps.id),
        'ytd', (SELECT jsonb_build_object('gross', coalesce(sum(s.gross), 0), 'cpp', coalesce(sum(s.cpp), 0), 'ei', coalesce(sum(s.ei), 0),
            'tax', coalesce(sum(s.tax), 0), 'vac', coalesce(sum(s.vac), 0), 'net', coalesce(sum(s.net), 0), 'n', count(*))
          FROM payroll_slips s WHERE s.staff_id = ps.id AND s.cheque_date < p_pay - 4 AND extract(year FROM s.cheque_date) = extract(year FROM p_pay)),
        'address', (SELECT s.address FROM payroll_slips s WHERE s.staff_id = ps.id AND s.address IS NOT NULL ORDER BY s.cheque_date DESC LIMIT 1),
        'onfile', (SELECT jsonb_agg(jsonb_build_object('cheque', s.cheque_date, 'gross', s.gross, 'net', s.net, 'cpp', s.cpp, 'ei', s.ei, 'tax', s.tax, 'file', s.file_name))
          FROM payroll_slips s WHERE s.staff_id = ps.id AND s.run_id IS NULL AND abs(s.cheque_date - p_pay) <= 4),
        'ytdl', (SELECT jsonb_object_agg(l, v) FROM (SELECT x ->> 'label' l, sum(coalesce(nullif(x ->> 'cur', '')::numeric, 0)) v
          FROM payroll_slips s CROSS JOIN LATERAL jsonb_array_elements(coalesce(s.earn, '[]'::jsonb) || coalesce(s.dfg, '[]'::jsonb) || coalesce(s.adj, '[]'::jsonb)) x
          WHERE s.staff_id = ps.id AND s.cheque_date < p_pay - 4 AND extract(year FROM s.cheque_date) = extract(year FROM p_pay) AND jsonb_typeof(x) = 'object' GROUP BY 1) q WHERE l IS NOT NULL),
        'ytdh', (SELECT sum((public._slip_parts(s.earn, s.adj, s.dfg) ->> 'hours')::numeric) FROM payroll_slips s
          WHERE s.staff_id = ps.id AND s.cheque_date < p_pay - 4 AND extract(year FROM s.cheque_date) = extract(year FROM p_pay)),
        'last', (SELECT jsonb_build_object('cheque', s.cheque_date, 'kind', s.kind, 'rate', s.rate, 'per_pay', s.per_pay, 'hours', s.reg_hours,
            'vac_pct', s.vac_pct, 'ben', (public._slip_parts(s.earn, s.adj, s.dfg) ->> 'ben')::numeric, 'gross', s.gross)
          FROM payroll_slips s WHERE s.staff_id = ps.id ORDER BY s.cheque_date DESC, s.gross DESC LIMIT 1)))
      FROM payroll_staff ps), '[]'::jsonb),
    'employer', (SELECT payroll_employer FROM company_settings LIMIT 1),
    'runs', coalesce((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'pay', r.pay_date, 'from', r.period_from, 'to', r.period_to, 'status', r.status,
        'by', r.made_by, 'at', r.made_at, 'final_by', r.final_by, 'final_at', r.final_at,
        'n', (SELECT count(*) FROM payroll_run_lines x WHERE x.run_id = r.id),
        'gross', (SELECT sum((x.l ->> 'gross')::numeric) FROM payroll_run_lines x WHERE x.run_id = r.id),
        'net', (SELECT sum((x.l ->> 'net')::numeric) FROM payroll_run_lines x WHERE x.run_id = r.id)) ORDER BY r.pay_date DESC, r.id DESC)
      FROM payroll_runs r WHERE r.status <> 'void'), '[]'::jsonb)) END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_run_info(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_run_info(date) TO authenticated;

-- one pay run and its lines
CREATE OR REPLACE FUNCTION public.payroll_run_get(p_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._src_owner() THEN NULL ELSE (SELECT to_jsonb(r) || jsonb_build_object('lines', coalesce((SELECT jsonb_agg(jsonb_build_object(
      'staff', x.staff_id, 'name', x.name, 'block', x.block, 'l', x.l, 'cheque_no', x.cheque_no, 'printed_at', x.printed_at) ORDER BY x.id)
      FROM payroll_run_lines x WHERE x.run_id = r.id), '[]'::jsonb)) FROM payroll_runs r WHERE r.id = p_id) END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_run_get(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_run_get(bigint) TO authenticated;

-- save a pay run as a draft (new, or the same draft again): p = {id?, pay, from, to, note, lines: [{staff?, user?, name, block, l}]}
CREATE OR REPLACE FUNCTION public.payroll_run_save(p jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE rid bigint := nullif(p ->> 'id', '')::bigint; x jsonb; sid bigint; who text := public._staff_name(public.current_app_user_id()); st text;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can run payroll'; END IF;
  IF nullif(p ->> 'pay', '') IS NULL THEN RAISE EXCEPTION 'Pick the pay day'; END IF;
  IF rid IS NULL THEN
    INSERT INTO payroll_runs (pay_date, period_from, period_to, note, made_by) VALUES ((p ->> 'pay')::date, nullif(p ->> 'from', '')::date, nullif(p ->> 'to', '')::date, nullif(p ->> 'note', ''), who)
      RETURNING id INTO rid;
  ELSE
    SELECT status INTO st FROM payroll_runs WHERE id = rid;
    IF st IS NULL THEN RAISE EXCEPTION 'That pay run is not there any more'; END IF;
    IF st <> 'draft' THEN RAISE EXCEPTION 'This pay run is final. It can not be changed (Undo it first).'; END IF;
    UPDATE payroll_runs SET pay_date = (p ->> 'pay')::date, period_from = nullif(p ->> 'from', '')::date, period_to = nullif(p ->> 'to', '')::date, note = nullif(p ->> 'note', '') WHERE id = rid;
    DELETE FROM payroll_run_lines WHERE run_id = rid;
  END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p -> 'lines', '[]'::jsonb)) LOOP
    sid := public._payroll_staff_for(nullif(x ->> 'staff', '')::bigint, nullif(x ->> 'user', '')::bigint, x ->> 'name', nullif(x ->> 'block', ''));
    INSERT INTO payroll_run_lines (run_id, staff_id, name, block, l) VALUES (rid, sid, x ->> 'name', nullif(x ->> 'block', ''), coalesce(x -> 'l', '{}'::jsonb))
      ON CONFLICT (run_id, staff_id) DO UPDATE SET l = excluded.l, name = excluded.name, block = excluded.block;
  END LOOP;
  RETURN rid;
END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_run_save(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_run_save(jsonb) TO authenticated;

-- make a pay run final: each line gets its cheque number and becomes a pay slip (so the totals, the Source estimate, the T4 check and the
-- next pay's year-to-date all count it). A slip the accountant's PDF brings later for the same person and day is then a duplicate.
CREATE OR REPLACE FUNCTION public.payroll_run_final(p_id bigint, p_first_cheque int) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE r payroll_runs; x payroll_run_lines; n int := 0; chq int := p_first_cheque; who text := public._staff_name(public.current_app_user_id()); sno int;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can run payroll'; END IF;
  SELECT * INTO r FROM payroll_runs WHERE id = p_id FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION 'That pay run is not there any more'; END IF;
  IF r.status <> 'draft' THEN RAISE EXCEPTION 'This pay run is already final'; END IF;
  FOR x IN SELECT * FROM payroll_run_lines WHERE run_id = p_id AND coalesce((l ->> 'net')::numeric, 0) <> 0 OR (run_id = p_id AND coalesce((l ->> 'gross')::numeric, 0) <> 0) ORDER BY block, name LOOP
    IF chq IS NOT NULL THEN UPDATE payroll_run_lines SET cheque_no = chq WHERE id = x.id; chq := chq + 1; END IF;
    SELECT coalesce(max(slip_no), 0) + 1 INTO sno FROM payroll_slips WHERE staff_id = x.staff_id AND cheque_date = r.pay_date;
    INSERT INTO payroll_slips (staff_id, cheque_date, period_from, period_to, slip_name, kind, rate, reg_hours, hours, gross, net, commission, vac, vac_pct,
        on_call, ot_pay, cpp, ei, tax, earn, dfg, adj, file_name, loaded_by, slip_no, block, run_id)
      VALUES (x.staff_id, r.pay_date, r.period_from, r.period_to, x.name, nullif(x.l ->> 'kind', ''), nullif(x.l ->> 'rate', '')::numeric,
        nullif(x.l ->> 'hours', '')::numeric, nullif(x.l ->> 'hours', '')::numeric, (x.l ->> 'gross')::numeric, (x.l ->> 'net')::numeric,
        nullif(x.l ->> 'com', '')::numeric, nullif(x.l ->> 'vac', '')::numeric, nullif(x.l ->> 'vac_pct', '')::numeric,
        nullif(x.l ->> 'oncall', '')::numeric, nullif(x.l ->> 'ot', '')::numeric,
        coalesce((x.l ->> 'cpp')::numeric, 0) + coalesce((x.l ->> 'cpp2')::numeric, 0), (x.l ->> 'ei')::numeric, (x.l ->> 'tax')::numeric,
        x.l -> 'earn', x.l -> 'dfg', x.l -> 'adj', 'App pay run #' || p_id, who, sno, x.block, p_id);
    n := n + 1;
  END LOOP;
  UPDATE payroll_runs SET status = 'final', final_by = who, final_at = now() WHERE id = p_id;
  IF chq IS NOT NULL THEN
    UPDATE company_settings SET payroll_employer = payroll_employer || jsonb_build_object('next_cheque', chq) WHERE true;
  END IF;
  PERFORM public._payroll_staff_refresh(x2.staff_id) FROM (SELECT DISTINCT staff_id FROM payroll_run_lines WHERE run_id = p_id) x2;
  RETURN jsonb_build_object('slips', n, 'next_cheque', chq);
END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_run_final(bigint, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_run_final(bigint, int) TO authenticated;

-- undo a final pay run (a mistake found before the cheques went out): its slips are taken off and it is a draft again
CREATE OR REPLACE FUNCTION public.payroll_run_undo(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE s bigint;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can run payroll'; END IF;
  DELETE FROM payroll_slips WHERE run_id = p_id;
  UPDATE payroll_run_lines SET cheque_no = NULL, printed_at = NULL WHERE run_id = p_id;
  UPDATE payroll_runs SET status = 'draft', final_by = NULL, final_at = NULL WHERE id = p_id;
  FOR s IN SELECT DISTINCT staff_id FROM payroll_run_lines WHERE run_id = p_id LOOP PERFORM public._payroll_staff_refresh(s); END LOOP;
END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_run_undo(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_run_undo(bigint) TO authenticated;

-- take a draft off (a final one is undone first)
CREATE OR REPLACE FUNCTION public.payroll_run_drop(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can run payroll'; END IF;
  IF EXISTS (SELECT 1 FROM payroll_runs WHERE id = p_id AND status = 'final') THEN RAISE EXCEPTION 'Undo the final pay run first'; END IF;
  UPDATE payroll_runs SET status = 'void' WHERE id = p_id;
END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_run_drop(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_run_drop(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.payroll_run_printed(p_id bigint) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  UPDATE payroll_run_lines SET printed_at = now() WHERE run_id = p_id AND public._src_owner() $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_run_printed(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_run_printed(bigint) TO authenticated;

-- a person's TD1 numbers and what comes off their pay each time: p = {td1_fed, td1_on, extra_tax, deps, cpp_exempt, ei_exempt, ben_per_pay, other_ded, vac_pct}
CREATE OR REPLACE FUNCTION public.payroll_tax_set(p_staff bigint, p_user bigint, p_name text, p jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE sid bigint;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  sid := public._payroll_staff_for(p_staff, p_user, p_name, NULL);
  INSERT INTO payroll_person_tax (staff_id) VALUES (sid) ON CONFLICT (staff_id) DO NOTHING;
  UPDATE payroll_person_tax SET td1_fed = nullif(p ->> 'td1_fed', '')::numeric, td1_on = nullif(p ->> 'td1_on', '')::numeric,
    extra_tax = coalesce(nullif(p ->> 'extra_tax', '')::numeric, 0), deps = coalesce(nullif(p ->> 'deps', '')::int, 0),
    cpp_exempt = coalesce((p ->> 'cpp_exempt')::boolean, false), ei_exempt = coalesce((p ->> 'ei_exempt')::boolean, false),
    ben_per_pay = nullif(p ->> 'ben_per_pay', '')::numeric, other_ded = coalesce(p -> 'other_ded', '[]'::jsonb), vac_pct = nullif(p ->> 'vac_pct', '')::numeric,
    updated_by = public._staff_name(public.current_app_user_id()), updated_at = now()
    WHERE staff_id = sid;
  RETURN sid;
END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_tax_set(bigint, bigint, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_tax_set(bigint, bigint, text, jsonb) TO authenticated;

-- the employer's numbers for the cheques and the T4 / ROE files: {legal_name, address, city, prov, postal, phone, bn (the 15-character payroll
-- account, RP0001), contact, contact_phone, contact_email, next_cheque, chq (cheque print shifts in mm: x, y)}. Kept in the database, never in the code.
CREATE OR REPLACE FUNCTION public.payroll_employer_set(p jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change payroll'; END IF;
  IF nullif(p ->> 'bn', '') IS NOT NULL AND upper(regexp_replace(p ->> 'bn', '\s', '', 'g')) !~ '^[0-9]{9}RP[0-9]{4}$' THEN
    RAISE EXCEPTION 'The payroll account number is 9 digits, RP, then 4 digits (like 123456789RP0001)'; END IF;
  UPDATE company_settings SET payroll_employer = coalesce(payroll_employer, '{}'::jsonb) || (p - 'bn')
    || CASE WHEN p ? 'bn' THEN jsonb_build_object('bn', upper(regexp_replace(coalesce(p ->> 'bn', ''), '\s', '', 'g'))) ELSE '{}'::jsonb END WHERE true;
END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_employer_set(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_employer_set(jsonb) TO authenticated;

-- the T4 file for a year: each person's pay slips added up (what the app and the accountant's slips have), with their T4 on file if loaded.
-- Their SIN is not here: it is typed in the browser when the file is made and never sent to the database.
CREATE OR REPLACE FUNCTION public.payroll_t4_file_data(p_year int) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._src_owner() THEN NULL ELSE jsonb_build_object('employer', (SELECT payroll_employer FROM company_settings LIMIT 1),
    'people', coalesce((SELECT jsonb_agg(jsonb_build_object('staff', ps.id, 'user', ps.app_user_id, 'name', ps.name,
        'slip_name', (SELECT s.slip_name FROM payroll_slips s WHERE s.staff_id = ps.id ORDER BY s.cheque_date DESC LIMIT 1),
        'address', (SELECT s.address FROM payroll_slips s WHERE s.staff_id = ps.id AND s.address IS NOT NULL ORDER BY s.cheque_date DESC LIMIT 1),
        'gross', g.gross, 'cpp', g.cpp, 'ei', g.ei, 'tax', g.tax, 'com', g.com, 'n', g.n,
        't4', (SELECT to_jsonb(t) - 'page_path' FROM payroll_t4 t WHERE t.staff_id = ps.id AND t.year = p_year LIMIT 1)) ORDER BY ps.name)
      FROM payroll_staff ps JOIN LATERAL (SELECT sum(s.gross) gross, sum(s.cpp) cpp, sum(s.ei) ei, sum(s.tax) tax,
          sum(coalesce((public._slip_parts(s.earn, s.adj, s.dfg) ->> 'com')::numeric, s.commission, 0)) com, count(*) n
        FROM payroll_slips s WHERE s.staff_id = ps.id AND extract(year FROM s.cheque_date) = p_year) g ON g.n > 0), '[]'::jsonb)) END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_t4_file_data(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_t4_file_data(int) TO authenticated;

-- the ROE file for one person: their pay slips (each pay period's insurable earnings and hours) back from their last day
CREATE OR REPLACE FUNCTION public.payroll_roe_file_data(p_staff bigint, p_user bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._src_owner() THEN NULL ELSE (SELECT jsonb_build_object('employer', (SELECT payroll_employer FROM company_settings LIMIT 1),
      'staff', ps.id, 'name', ps.name, 'started_on', ps.started_on, 'left_on', ps.left_on,
      'slip_name', (SELECT s.slip_name FROM payroll_slips s WHERE s.staff_id = ps.id ORDER BY s.cheque_date DESC LIMIT 1),
      'address', (SELECT s.address FROM payroll_slips s WHERE s.staff_id = ps.id AND s.address IS NOT NULL ORDER BY s.cheque_date DESC LIMIT 1),
      'slips', coalesce((SELECT jsonb_agg(jsonb_build_object('cheque', s.cheque_date, 'from', s.period_from, 'to', s.period_to, 'gross', s.gross,
          'hours', coalesce(s.hours, s.reg_hours), 'vac', s.vac) ORDER BY s.cheque_date DESC, s.slip_no)
        FROM payroll_slips s WHERE s.staff_id = ps.id), '[]'::jsonb),
      'roe', (SELECT to_jsonb(r) - 'page_path' FROM payroll_roe r WHERE r.staff_id = ps.id ORDER BY r.id DESC LIMIT 1))
    FROM payroll_staff ps WHERE ps.id = coalesce(p_staff, (SELECT id FROM payroll_staff WHERE app_user_id = p_user))) END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_roe_file_data(bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_roe_file_data(bigint, bigint) TO authenticated;

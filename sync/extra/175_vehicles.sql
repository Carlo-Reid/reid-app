-- Bank → Vehicles: the company's vehicles (leased, financed or owned), what each payment is, and its payments found in the bank.
-- A vehicle's payments are the bank lines out to its lender for its payment amount (found automatically, or tied by hand).
CREATE TABLE IF NOT EXISTS public.vehicles (
  id bigserial PRIMARY KEY, name text NOT NULL, year int, make_model text, plate text, vin text, driver text,
  lender text, kind text NOT NULL DEFAULT 'lease', payment numeric(12,2), frequency text NOT NULL DEFAULT 'monthly',
  first_payment date, last_payment date, payments_total int, balance_owing numeric(12,2), buyout numeric(12,2),
  bank_pattern text, paid_off boolean NOT NULL DEFAULT false, notes text, active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(), created_by bigint);
CREATE TABLE IF NOT EXISTS public.bank_vehicle_links (
  bank_id bigint PRIMARY KEY REFERENCES public.bank_transactions(id) ON DELETE CASCADE,
  vehicle_id bigint NOT NULL REFERENCES public.vehicles(id) ON DELETE CASCADE, how text NOT NULL DEFAULT 'auto', made_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS bank_vehicle_links_v ON public.bank_vehicle_links (vehicle_id);
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY; ALTER TABLE public.bank_vehicle_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vehicles, public.bank_vehicle_links FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._veh_step(f text) RETURNS interval LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE f WHEN 'weekly' THEN interval '7 days' WHEN 'biweekly' THEN interval '14 days' WHEN 'semimonthly' THEN interval '15 days' WHEN 'yearly' THEN interval '1 year' ELSE interval '1 month' END $f$;

-- find a vehicle's payments in the bank: lines out for its payment amount, to its lender (the words in "In the bank as", or the lender's name)
CREATE OR REPLACE FUNCTION public.vehicle_match(p_id bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v vehicles; pat text; n int;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  SELECT * INTO v FROM vehicles WHERE id = p_id; IF v.id IS NULL THEN RAISE EXCEPTION 'No such vehicle'; END IF;
  DELETE FROM bank_vehicle_links WHERE vehicle_id = p_id AND how = 'auto';
  IF coalesce(v.payment, 0) <= 0 THEN RETURN 0; END IF;
  pat := upper(btrim(coalesce(nullif(v.bank_pattern, ''), split_part(coalesce(v.lender, ''), ' ', 1))));
  IF pat = '' THEN RETURN 0; END IF;
  INSERT INTO bank_vehicle_links (bank_id, vehicle_id, how)
    SELECT b.id, p_id, 'auto' FROM bank_transactions b
    WHERE b.amount_out BETWEEN v.payment - 0.005 AND v.payment + 0.005 AND upper(b.description) LIKE '%' || pat || '%'
      AND (v.first_payment IS NULL OR b.txn_date >= v.first_payment - 20) AND (v.last_payment IS NULL OR b.txn_date <= v.last_payment + 20)
      AND NOT EXISTS (SELECT 1 FROM bank_vehicle_links k WHERE k.bank_id = b.id)
    ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT; RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION public.vehicle_save(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v bigint := nullif(p ->> 'id', '')::bigint; n int;
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  IF nullif(btrim(p ->> 'name'), '') IS NULL THEN RAISE EXCEPTION 'Give the vehicle a name (e.g. "Ford Transit van")'; END IF;
  IF v IS NULL THEN
    INSERT INTO vehicles (name, created_by) VALUES (btrim(p ->> 'name'), public.current_app_user_id()) RETURNING id INTO v;
  END IF;
  UPDATE vehicles SET name = btrim(p ->> 'name'), year = nullif(p ->> 'year', '')::int, make_model = nullif(btrim(p ->> 'make_model'), ''), plate = nullif(btrim(p ->> 'plate'), ''),
    vin = nullif(btrim(p ->> 'vin'), ''), driver = nullif(btrim(p ->> 'driver'), ''), lender = nullif(btrim(p ->> 'lender'), ''), kind = coalesce(nullif(p ->> 'kind', ''), 'lease'),
    payment = nullif(p ->> 'payment', '')::numeric, frequency = coalesce(nullif(p ->> 'frequency', ''), 'monthly'), first_payment = nullif(p ->> 'first_payment', '')::date,
    last_payment = nullif(p ->> 'last_payment', '')::date, payments_total = nullif(p ->> 'payments_total', '')::int, balance_owing = nullif(p ->> 'balance_owing', '')::numeric,
    buyout = nullif(p ->> 'buyout', '')::numeric, bank_pattern = nullif(btrim(p ->> 'bank_pattern'), ''), paid_off = coalesce((p ->> 'paid_off')::boolean, false),
    notes = nullif(btrim(p ->> 'notes'), ''), active = coalesce((p ->> 'active')::boolean, true)
  WHERE id = v;
  n := public.vehicle_match(v);
  RETURN jsonb_build_object('id', v, 'found', n);
END $f$;

CREATE OR REPLACE FUNCTION public.vehicle_delete(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF; DELETE FROM vehicles WHERE id = p_id; END $f$;

-- tie or untie a bank line by hand
CREATE OR REPLACE FUNCTION public.vehicle_link(p_bank bigint, p_vehicle bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._bank_owner() THEN RAISE EXCEPTION 'Only owners can change the bank'; END IF;
  IF p_vehicle IS NULL THEN DELETE FROM bank_vehicle_links WHERE bank_id = p_bank; RETURN; END IF;
  INSERT INTO bank_vehicle_links (bank_id, vehicle_id, how) VALUES (p_bank, p_vehicle, 'by hand') ON CONFLICT (bank_id) DO UPDATE SET vehicle_id = EXCLUDED.vehicle_id, how = 'by hand', made_at = now();
END $f$;

-- the list: each vehicle with what's been paid, when it's next due, what's left, and whether it's paid off
CREATE OR REPLACE FUNCTION public.vehicles_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._bank_owner() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(j ORDER BY (j ->> 'done')::boolean, j ->> 'name') FROM (
    SELECT jsonb_build_object('id', v.id, 'name', v.name, 'year', v.year, 'make_model', v.make_model, 'plate', v.plate, 'vin', v.vin, 'driver', v.driver, 'lender', v.lender, 'kind', v.kind,
      'payment', v.payment, 'frequency', v.frequency, 'first_payment', v.first_payment, 'last_payment', v.last_payment, 'payments_total', v.payments_total,
      'balance_owing', v.balance_owing, 'buyout', v.buyout, 'bank_pattern', v.bank_pattern, 'paid_off', v.paid_off, 'notes', v.notes, 'active', v.active,
      'paid_n', s.n, 'paid_sum', s.sum, 'first_paid', s.first, 'last_paid', s.last, 'year_sum', s.ysum, 'year_n', s.yn,
      'next_due', CASE WHEN v.paid_off THEN NULL ELSE (coalesce(s.last, v.first_payment) + CASE WHEN s.last IS NULL THEN interval '0' ELSE public._veh_step(v.frequency) END)::date END,
      'left_n', CASE WHEN v.payments_total IS NOT NULL THEN greatest(v.payments_total - s.n, 0) END,
      'left_sum', CASE WHEN v.balance_owing IS NOT NULL THEN v.balance_owing WHEN v.payments_total IS NOT NULL THEN greatest(v.payments_total - s.n, 0) * coalesce(v.payment, 0) END,
      'late', NOT v.paid_off AND s.last IS NOT NULL AND (s.last + public._veh_step(v.frequency) + interval '10 days')::date < current_date,
      'done', v.paid_off OR (v.payments_total IS NOT NULL AND s.n >= v.payments_total) OR (v.last_payment IS NOT NULL AND v.last_payment < current_date - 30),
      'payments', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'date', b.txn_date, 'amount', b.amount_out, 'account', b.account, 'how', k.how) ORDER BY b.txn_date DESC), '[]')
                   FROM (SELECT * FROM bank_vehicle_links k2 WHERE k2.vehicle_id = v.id) k JOIN bank_transactions b ON b.id = k.bank_id)) AS j
    FROM vehicles v
    CROSS JOIN LATERAL (SELECT count(*)::int n, coalesce(sum(b.amount_out), 0) sum, min(b.txn_date) first, max(b.txn_date) last,
                               coalesce(sum(b.amount_out) FILTER (WHERE b.txn_date >= date_trunc('year', current_date)), 0) ysum, count(*) FILTER (WHERE b.txn_date >= date_trunc('year', current_date))::int yn
                        FROM bank_vehicle_links k JOIN bank_transactions b ON b.id = k.bank_id WHERE k.vehicle_id = v.id) s) x), '[]') END $f$;

-- payments in the bank that look like a vehicle's (the same amount to a lease or loan company, again and again) and aren't a vehicle yet
CREATE OR REPLACE FUNCTION public.vehicle_suggest() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN NOT public._bank_owner() THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('payee', payee, 'amount', amount_out, 'n', n, 'first', f, 'last', l,
           'frequency', CASE WHEN gap < 10 THEN 'weekly' WHEN gap < 20 THEN 'biweekly' WHEN gap < 45 THEN 'monthly' ELSE 'other' END) ORDER BY l DESC, n DESC) FROM (
    SELECT b.payee, b.amount_out, count(*) n, min(b.txn_date) f, max(b.txn_date) l, (max(b.txn_date) - min(b.txn_date))::numeric / greatest(count(*) - 1, 1) gap
    FROM bank_transactions b
    WHERE b.amount_out > 50 AND (b.description ~* 'LEAS|LNS/PRE|LOAN|CREDIT CA|FORD|HYUNDAI|TOYOTA|GM FIN|HONDA|NISSAN|RLS/LOY|AUTO|MOTOR|FLEET|RENT' AND b.description !~* 'MASTERCARD|AMEX|VISA|PC MC|INSUR|CONDOM|PREMIERE|TAX')
      AND NOT EXISTS (SELECT 1 FROM bank_vehicle_links k WHERE k.bank_id = b.id)
    GROUP BY b.payee, b.amount_out HAVING count(*) >= 3 AND max(b.txn_date) >= current_date - 400) s
    WHERE NOT EXISTS (SELECT 1 FROM vehicles v WHERE v.payment = s.amount_out AND upper(s.payee) LIKE '%' || upper(coalesce(nullif(v.bank_pattern, ''), split_part(coalesce(v.lender, ''), ' ', 1))) || '%')), '[]') END $f$;

REVOKE EXECUTE ON FUNCTION public.vehicle_match(bigint), public.vehicle_save(jsonb), public.vehicle_delete(bigint), public.vehicle_link(bigint, bigint), public.vehicles_list(), public.vehicle_suggest() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vehicle_match(bigint), public.vehicle_save(jsonb), public.vehicle_delete(bigint), public.vehicle_link(bigint, bigint), public.vehicles_list(), public.vehicle_suggest() TO authenticated;

-- bank lines show the vehicle they paid
DO $do$
DECLARE src text := pg_get_functiondef('public._bank_att(bigint)'::regprocedure);
BEGIN
  IF src LIKE '%bank_vehicle_links%' THEN RETURN; END IF;
  src := replace(src, $a$'files', (SELECT$a$, $a$'vehicle', (SELECT jsonb_build_object('id', v.id, 'name', v.name, 'lender', v.lender, 'how', k.how) FROM bank_vehicle_links k JOIN vehicles v ON v.id = k.vehicle_id WHERE k.bank_id = p_id),
    'files', (SELECT$a$);
  IF src NOT LIKE '%bank_vehicle_links%' THEN RAISE EXCEPTION '_bank_att: anchor not found'; END IF;
  EXECUTE src;
END $do$;
NOTIFY pgrst, 'reload schema';

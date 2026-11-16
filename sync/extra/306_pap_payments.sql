-- =====================================================================
-- Security page: PAP / EFT payments (George, Nov 16, 2026).
--   * A plan for each customer who pays by pre-authorized debit: what it is for, how much a month, the draw day (7th or 17th),
--     and the reference AcceptPay sends back on its settlement file. Two kinds:
--       service = a monthly service that goes on (security monitoring, a maintenance plan): one charge each month.
--       plan    = a payment plan: a set total paid over a set number of months (12 or more).
--   * One record per plan, kept line by line (pap_entries): the monthly charge, each payment received, an NSF or chargeback
--     that came back, the NSF fee, a change made by hand. A year of it prints as one invoice with its 12 months.
--   * A settlement file (pap_inbox, the table the mailbox reader keeps) is read row by row: Approved = a payment received,
--     NSF, Chargeback, or anything else. Nothing is posted until an owner looks at it and presses Post.
--     A row is never posted twice (its Transaction ID), and a posted file can be undone.
--   * NSF: the payment that was counted stays; a new charge for the returned amount goes on, plus the NSF fee; flagged for the office.
--     Chargeback: the payment stays; a new charge says what came back and why; flagged; no fee.
--     Anything else (account closed, frozen, stop payment): flagged with the reason and the plan is marked paused.
--   * No bank details are read or kept here. Safe to run more than once.
-- Who: the Security page's people (_sec_ok: owners and "Security page" staff) see it, set up plans and follow up.
--      Posting a file, undoing one, the NSF fee and deleting are owners only (_pap_owner).
-- =====================================================================
-- The NSF fee is $45 (George, Nov 16). It is put in once, when the column is made, so a fee an owner types later is never put back.
DO $do$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'company_settings' AND column_name = 'pap_nsf_fee') THEN
    ALTER TABLE public.company_settings ADD COLUMN pap_nsf_fee numeric(10,2);
    UPDATE public.company_settings SET pap_nsf_fee = 45 WHERE true;
  END IF;
END $do$;

CREATE OR REPLACE FUNCTION public._pap_owner() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(public._is_owner(), false) $f$;
CREATE OR REPLACE FUNCTION public._pap_today() RETURNS date LANGUAGE sql STABLE AS $f$ SELECT (now() AT TIME ZONE 'America/Toronto')::date $f$;
CREATE OR REPLACE FUNCTION public._pap_me() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce(nullif(btrim(public._emp_name((SELECT u.employee_id FROM app_users u WHERE u.id = public.current_app_user_id()))), ''), 'Someone') $f$;

CREATE TABLE IF NOT EXISTS public.pap_plans (
  id           bigserial PRIMARY KEY,
  customer_id  bigint NOT NULL,
  kind         text NOT NULL DEFAULT 'service' CHECK (kind IN ('service', 'plan')),
  label        text NOT NULL,
  brand        text NOT NULL DEFAULT 'reid' CHECK (brand IN ('reid', 'accurate', 'hsg')),
  amount       numeric(12,2) NOT NULL CHECK (amount > 0),
  draw_day     integer NOT NULL DEFAULT 7 CHECK (draw_day IN (7, 17)),
  reference    text,
  start_on     date NOT NULL,
  months       integer CHECK (months IS NULL OR months BETWEEN 1 AND 240),
  total        numeric(12,2),
  invoice_no   text,
  tax_in       boolean NOT NULL DEFAULT true,
  status       text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'ended')),
  pause_why    text,
  paused_inbox bigint,
  end_on       date,
  note         text,
  created_by   text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS pap_plans_cust ON public.pap_plans (customer_id);
ALTER TABLE public.pap_plans ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_plans FROM PUBLIC, anon, authenticated;

-- payment: money received. Every other kind is money owed (adjust can be a minus: a credit).
CREATE TABLE IF NOT EXISTS public.pap_entries (
  id          bigserial PRIMARY KEY,
  plan_id     bigint NOT NULL REFERENCES public.pap_plans(id) ON DELETE CASCADE,
  kind        text NOT NULL CHECK (kind IN ('charge', 'payment', 'nsf', 'chargeback', 'returned', 'fee', 'adjust')),
  on_date     date NOT NULL,
  period      date NOT NULL,
  amount      numeric(12,2) NOT NULL,
  txn_id      text,
  inbox_id    bigint,
  ref_entry   bigint,
  note        text,
  by_name     text,
  created_at  timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS pap_entries_plan ON public.pap_entries (plan_id, period);
CREATE INDEX IF NOT EXISTS pap_entries_inbox ON public.pap_entries (inbox_id) WHERE inbox_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS pap_entries_charge ON public.pap_entries (plan_id, period) WHERE kind = 'charge';
CREATE UNIQUE INDEX IF NOT EXISTS pap_entries_txn ON public.pap_entries (txn_id, kind) WHERE txn_id IS NOT NULL;
ALTER TABLE public.pap_entries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_entries FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.pap_flags (
  id          bigserial PRIMARY KEY,
  kind        text NOT NULL CHECK (kind IN ('nsf', 'chargeback', 'other', 'noplan', 'amount', 'missing')),
  row_kind    text,
  plan_id     bigint,
  customer_id bigint,
  inbox_id    bigint,
  txn_id      text,
  on_date     date,
  ret_date    date,
  amount      numeric(12,2),
  reason      text,
  who         text,
  ref         text,
  status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done')),
  done_by     text,
  done_at     timestamptz,
  done_note   text,
  notice_at   timestamptz,
  notice_to   text,
  notice_by   text,
  created_at  timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS pap_flags_open ON public.pap_flags (status, created_at DESC);
CREATE INDEX IF NOT EXISTS pap_flags_plan ON public.pap_flags (plan_id);
CREATE UNIQUE INDEX IF NOT EXISTS pap_flags_txn ON public.pap_flags (txn_id, kind) WHERE txn_id IS NOT NULL;
ALTER TABLE public.pap_flags ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_flags FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.pap_settle (
  inbox_id   bigint PRIMARY KEY,
  posted_at  timestamptz NOT NULL DEFAULT now(),
  posted_by  text,
  deposit    numeric(12,2),
  fees       numeric(12,2),
  counts     jsonb,
  kinds      jsonb);
ALTER TABLE public.pap_settle ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_settle FROM PUBLIC, anon, authenticated;

-- a customer who gets the NSF notice by itself from now on (turned on by staff after their first NSF)
CREATE TABLE IF NOT EXISTS public.pap_cust (
  customer_id bigint PRIMARY KEY,
  nsf_auto    boolean NOT NULL DEFAULT false,
  set_by      text,
  set_at      timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.pap_cust ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_cust FROM PUBLIC, anon, authenticated;

-- ---------- small readers ----------
CREATE OR REPLACE FUNCTION public._pap_num(t text) RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE s text := regexp_replace(coalesce(t, ''), '[$,\s]', '', 'g'); neg boolean := false;
BEGIN
  IF s ~ '^\(.*\)$' THEN neg := true; s := substring(s from 2 for length(s) - 2); END IF;
  IF s ~ '^-' THEN neg := NOT neg; s := substring(s from 2); END IF;
  IF s !~ '^[0-9]+(\.[0-9]+)?$' THEN RETURN NULL; END IF;
  RETURN round(CASE WHEN neg THEN -1 ELSE 1 END * s::numeric, 2);
END $f$;

CREATE OR REPLACE FUNCTION public._pap_date(t text) RETURNS date LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE s text := btrim(coalesce(t, '')); m text[];
BEGIN
  IF s = '' THEN RETURN NULL; END IF;
  BEGIN
    IF s ~ '^\d{4}-\d{1,2}-\d{1,2}' THEN RETURN to_date(substring(s from '^\d{4}-\d{1,2}-\d{1,2}'), 'YYYY-MM-DD'); END IF;
    m := regexp_match(s, '^(\d{1,2})[-\s/]([A-Za-z]{3})[A-Za-z]*[-\s/,]+(\d{4})');
    IF m IS NOT NULL THEN RETURN to_date(m[1] || '-' || initcap(m[2]) || '-' || m[3], 'DD-Mon-YYYY'); END IF;
    m := regexp_match(s, '^([A-Za-z]{3})[A-Za-z]*\.?\s+(\d{1,2}),?\s+(\d{4})');
    IF m IS NOT NULL THEN RETURN to_date(m[2] || '-' || initcap(m[1]) || '-' || m[3], 'DD-Mon-YYYY'); END IF;
    m := regexp_match(s, '^(\d{1,2})/(\d{1,2})/(\d{4})');
    IF m IS NOT NULL THEN RETURN make_date(m[3]::int, m[1]::int, m[2]::int); END IF;   -- month first, the way AcceptPay writes "9/14/2026"
  EXCEPTION WHEN others THEN RETURN NULL; END;
  RETURN NULL;
END $f$;

-- a reference the same way on both sides: "C#1234", "c 1234", "1234.0" and "1234" are all 1234
CREATE OR REPLACE FUNCTION public._pap_ref(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT nullif(regexp_replace(regexp_replace(regexp_replace(lower(btrim(coalesce(t, ''))), '\.0+$', ''), '\s+', '', 'g'), '^c#?(?=[0-9])', ''), '') $f$;

-- which column of the file is which (0 = the first one, -1 = not there)
CREATE OR REPLACE FUNCTION public._pap_col(p_cols jsonb, p_re text) RETURNS integer LANGUAGE sql IMMUTABLE AS $f$
  SELECT coalesce((SELECT (o - 1)::int FROM jsonb_array_elements_text(coalesce(p_cols, '[]'::jsonb)) WITH ORDINALITY t(c, o) WHERE c ~* p_re ORDER BY o LIMIT 1), -1) $f$;

-- what a row of the settlement file is: paid, nsf, chargeback or other. AcceptPay: Response "Approved" and Settled "AA" = paid.
CREATE OR REPLACE FUNCTION public._pap_kind(p_resp text, p_settled text, p_more text) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  WITH w AS (SELECT lower(concat_ws(' ', p_resp, p_settled, p_more)) AS a, lower(btrim(coalesce(p_resp, ''))) AS r, upper(btrim(coalesce(p_settled, ''))) AS s)
  SELECT CASE
    WHEN a ~ '(^|[^a-z])nsf([^a-z]|$)|non[- ]?sufficient|insufficient|not sufficient' THEN 'nsf'
    WHEN a ~ 'charge[- ]?back|chargeback|disput' OR s = 'CB' THEN 'chargeback'
    WHEN r ~ '^(approved|success|successful|paid|complete|completed|settled)$' AND s IN ('', 'AA') THEN 'paid'
    WHEN r = '' AND s = 'AA' THEN 'paid'
    ELSE 'other' END FROM w $f$;

-- ---------- the monthly charge fills itself in ----------
-- service: one charge every month from the start month, on the draw day, while the plan is not ended.
-- plan: one charge a month for its number of months; the last one takes up any cents left over.
CREATE OR REPLACE FUNCTION public._pap_fill() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
  INSERT INTO pap_entries (plan_id, kind, on_date, period, amount)
  SELECT p.id, 'charge', (g.m + (p.draw_day - 1))::date, g.m,
         CASE WHEN p.kind = 'plan' AND p.months IS NOT NULL AND g.n = p.months
              THEN greatest(coalesce(p.total, p.amount * p.months) - p.amount * (p.months - 1), 0.01) ELSE p.amount END
  FROM pap_plans p
  CROSS JOIN LATERAL (
    SELECT s::date AS m, (row_number() OVER (ORDER BY s))::int AS n
    FROM generate_series(date_trunc('month', p.start_on)::timestamp,
           least(date_trunc('month', public._pap_today())::timestamp,
                 CASE WHEN p.status = 'ended' THEN date_trunc('month', coalesce(p.end_on, p.start_on - 1))::timestamp ELSE timestamp '9999-01-01' END,
                 CASE WHEN p.kind = 'plan' AND p.months IS NOT NULL THEN (date_trunc('month', p.start_on) + make_interval(months => p.months - 1))::timestamp ELSE timestamp '9999-01-01' END),
           interval '1 month') s) g
  WHERE (g.m + (p.draw_day - 1))::date <= public._pap_today()
  ON CONFLICT (plan_id, period) WHERE kind = 'charge' DO NOTHING $f$;

CREATE OR REPLACE FUNCTION public._pap_cust(p_id bigint) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT coalesce((SELECT coalesce(c.merged_into_id, c.id) FROM customers c WHERE c.id = p_id), p_id) $f$;

-- ---------- one settlement file, row by row, with the plan each row belongs to ----------
-- p_kinds: what an owner picked by hand for a row, {"<row number>": "paid" | "nsf" | "chargeback" | "other" | "skip"}
CREATE OR REPLACE FUNCTION public._pap_settle_rows(p_inbox bigint, p_kinds jsonb DEFAULT NULL)
RETURNS TABLE (i int, txn text, pdate date, rdate date, typ text, resp text, setl text, amt numeric, ref text, who text,
               kind text, read_kind text, plan_id bigint, how text, customer_id bigint, already boolean, pay_entry bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' SET statement_timeout = '90s' AS $f$
DECLARE f pap_inbox; c jsonb;
  c_txn int; c_pd int; c_rd int; c_ty int; c_re int; c_se int; c_am int; c_rf int; c_fn int; c_ln int; c_nm int; c_ds int;
BEGIN
  SELECT * INTO f FROM pap_inbox WHERE id = p_inbox;
  IF f.id IS NULL OR f.tbl IS NULL OR f.cols IS NULL THEN RETURN; END IF;
  c := f.cols;
  c_txn := public._pap_col(c, 'transaction\s*(id|#|no)|^trans.*id$|^txn');
  c_pd := public._pap_col(c, 'process');  c_rd := public._pap_col(c, 'return');
  c_ty := public._pap_col(c, '^type$');   c_re := public._pap_col(c, 'response|^status$|result');
  c_se := public._pap_col(c, 'settle');   c_am := public._pap_col(c, '^amount$|amount');
  c_rf := public._pap_col(c, '^ref(erence)?\M'); c_fn := public._pap_col(c, 'first'); c_ln := public._pap_col(c, 'last');
  c_nm := public._pap_col(c, '^(customer|client)?\s*name$|payor|payer');
  c_ds := public._pap_col(c, 'desc|reason|comment|note|message');
  IF c_am < 0 THEN RETURN; END IF;
  RETURN QUERY
  WITH r AS MATERIALIZED (
    SELECT (o - 1)::int AS i,
           coalesce(nullif(btrim(x ->> c_txn), ''), 'f' || p_inbox || 'r' || o) AS txn,
           coalesce(public._pap_date(x ->> c_pd), public._pap_date(x ->> c_rd), f.received_at::date) AS pdate,
           public._pap_date(x ->> c_rd) AS rdate,
           btrim(coalesce(x ->> c_ty, '')) AS typ, btrim(coalesce(x ->> c_re, '')) AS resp, btrim(coalesce(x ->> c_se, '')) AS setl,
           public._pap_num(x ->> c_am) AS amt, btrim(coalesce(x ->> c_rf, '')) AS ref,
           btrim(replace(CASE WHEN c_fn >= 0 OR c_ln >= 0 THEN concat_ws(' ', nullif(btrim(coalesce(x ->> c_fn, '')), ''), nullif(btrim(coalesce(x ->> c_ln, '')), ''))
                              ELSE coalesce(x ->> c_nm, '') END, '&amp;', '&')) AS who,
           btrim(coalesce(x ->> c_ds, '')) AS more
    FROM jsonb_array_elements(f.tbl) WITH ORDINALITY t(x, o)
    WHERE jsonb_typeof(x) = 'array'),
  k AS MATERIALIZED (
    SELECT r.*, public._pap_kind(r.resp, r.setl, r.more) AS read_kind,
           coalesce(nullif(p_kinds ->> (r.i::text), ''), public._pap_kind(r.resp, r.setl, r.more)) AS kind
    FROM r WHERE r.amt IS NOT NULL),
  -- 1) by the reference on the plan
  byref AS MATERIALIZED (
    SELECT k.i, (array_agg(p.id ORDER BY (p.amount = k.amt) DESC, (p.status = 'active') DESC, p.id))[1] AS plan_id,
           count(*) AS n, count(*) FILTER (WHERE p.amount = k.amt) AS n_amt
    FROM k JOIN pap_plans p ON public._pap_ref(p.reference) = public._pap_ref(k.ref) AND p.status <> 'ended'
    WHERE public._pap_ref(k.ref) IS NOT NULL GROUP BY k.i),
  -- 2) the rest: by the customer the row matches (customer number, address code, name), when that customer has one plan
  need AS (SELECT k.i, k.ref, k.who FROM k LEFT JOIN byref b ON b.i = k.i WHERE b.i IS NULL OR (b.n > 1 AND b.n_amt <> 1)),
  m AS MATERIALIZED (SELECT * FROM public.pap_match((SELECT coalesce(jsonb_agg(jsonb_build_object('i', need.i, 'num', need.ref, 'name', need.who, 'phone', '')), '[]'::jsonb) FROM need))
                     WHERE EXISTS (SELECT 1 FROM need)),
  bycust AS MATERIALIZED (
    SELECT k.i, m.customer_id, (array_agg(p.id ORDER BY (p.amount = k.amt) DESC, (p.status = 'active') DESC, p.id))[1] AS plan_id,
           count(p.id) AS n, count(p.id) FILTER (WHERE p.amount = k.amt) AS n_amt
    FROM k JOIN m ON m.i = k.i LEFT JOIN pap_plans p ON public._pap_cust(p.customer_id) = m.customer_id AND p.status <> 'ended'
    GROUP BY k.i, m.customer_id),
  j AS (
    SELECT k.*,
           CASE WHEN b.i IS NOT NULL AND (b.n = 1 OR b.n_amt = 1) THEN b.plan_id
                WHEN bc.i IS NOT NULL AND (bc.n = 1 OR bc.n_amt = 1) THEN bc.plan_id END AS plan_id,
           CASE WHEN b.i IS NOT NULL AND (b.n = 1 OR b.n_amt = 1) THEN 'reference'
                WHEN bc.i IS NOT NULL AND (bc.n = 1 OR bc.n_amt = 1) THEN 'customer'
                WHEN coalesce(b.n, 0) > 1 OR coalesce(bc.n, 0) > 1 THEN 'several'
                WHEN bc.customer_id IS NOT NULL THEN 'no plan' ELSE 'not found' END AS how,
           bc.customer_id AS m_cust
    FROM k LEFT JOIN byref b ON b.i = k.i LEFT JOIN bycust bc ON bc.i = k.i)
  SELECT j.i, j.txn, j.pdate, j.rdate, j.typ, j.resp, j.setl, j.amt, j.ref, j.who, j.kind, j.read_kind, j.plan_id, j.how,
         coalesce((SELECT public._pap_cust(p.customer_id) FROM pap_plans p WHERE p.id = j.plan_id), j.m_cust),
         (EXISTS (SELECT 1 FROM pap_entries e WHERE e.txn_id = j.txn AND e.kind = CASE j.kind WHEN 'paid' THEN 'payment' WHEN 'other' THEN 'returned' ELSE j.kind END)
          OR EXISTS (SELECT 1 FROM pap_flags g WHERE g.txn_id = j.txn AND g.kind IN (CASE WHEN j.kind = 'paid' THEN 'noplan' ELSE j.kind END, 'noplan') AND coalesce(g.row_kind, j.kind) = j.kind)),
         -- the payment this row is about, when it is already counted: the same Transaction ID, or the same plan, day and amount
         CASE WHEN j.kind IN ('nsf', 'chargeback', 'other') THEN
           coalesce((SELECT e.id FROM pap_entries e WHERE e.kind = 'payment' AND e.txn_id = j.txn LIMIT 1),
                    (SELECT e.id FROM pap_entries e WHERE e.kind = 'payment' AND e.plan_id = j.plan_id AND e.on_date = j.pdate AND e.amount = j.amt
                       AND NOT EXISTS (SELECT 1 FROM pap_entries z WHERE z.ref_entry = e.id) ORDER BY e.id LIMIT 1)) END
  FROM j ORDER BY j.i;
END $f$;

-- post one row to a plan (used by posting a file, and by "post it to a plan" on a row that had no plan)
CREATE OR REPLACE FUNCTION public._pap_post_row(p_plan bigint, p_kind text, p_txn text, p_pdate date, p_rdate date, p_amt numeric,
                                               p_ref text, p_who text, p_resp text, p_inbox bigint, p_pay bigint, p_by text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE pl pap_plans; v_fee numeric; v_per date := date_trunc('month', p_pdate)::date; v_day date := coalesce(p_rdate, p_pdate);
        v_why text := nullif(btrim(coalesce(p_resp, '')), ''); v_cust bigint;
BEGIN
  SELECT * INTO pl FROM pap_plans WHERE id = p_plan;
  IF pl.id IS NULL THEN RETURN 'no plan'; END IF;
  v_cust := public._pap_cust(pl.customer_id);
  IF p_kind = 'paid' THEN
    INSERT INTO pap_entries (plan_id, kind, on_date, period, amount, txn_id, inbox_id, note, by_name)
    VALUES (pl.id, 'payment', p_pdate, v_per, p_amt, p_txn, p_inbox, 'EFT payment received', p_by)
    ON CONFLICT (txn_id, kind) WHERE txn_id IS NOT NULL DO NOTHING;
    IF NOT FOUND THEN RETURN 'already'; END IF;
    IF p_amt <> pl.amount AND NOT (pl.kind = 'plan' AND pl.months IS NOT NULL
         AND p_amt = greatest(coalesce(pl.total, pl.amount * pl.months) - pl.amount * (pl.months - 1), 0.01)) THEN
      INSERT INTO pap_flags (kind, row_kind, plan_id, customer_id, inbox_id, txn_id, on_date, amount, reason, who, ref)
      VALUES ('amount', 'paid', pl.id, v_cust, p_inbox, p_txn, p_pdate, p_amt,
              'The payment was ' || to_char(p_amt, 'FM$999,999,990.00') || '. The plan says ' || to_char(pl.amount, 'FM$999,999,990.00') || ' a month.', p_who, p_ref)
      ON CONFLICT (txn_id, kind) WHERE txn_id IS NOT NULL DO NOTHING;
    END IF;
    RETURN 'payment';
  END IF;
  IF p_kind NOT IN ('nsf', 'chargeback', 'other') THEN RETURN 'skipped'; END IF;
  -- the flag first: if this row was flagged before, nothing more is done
  INSERT INTO pap_flags (kind, row_kind, plan_id, customer_id, inbox_id, txn_id, on_date, ret_date, amount, reason, who, ref)
  VALUES (p_kind, p_kind, pl.id, v_cust, p_inbox, p_txn, p_pdate, p_rdate, p_amt,
          CASE p_kind WHEN 'nsf' THEN 'NSF: not enough money in the account' WHEN 'chargeback' THEN 'Chargeback: the customer''s bank took the payment back' ELSE coalesce(v_why, 'Not approved') END
            || CASE WHEN v_why IS NOT NULL AND p_kind <> 'other' AND lower(v_why) NOT IN ('nsf', 'chargeback', 'cb') THEN ' (the file says: ' || v_why || ')' ELSE '' END, p_who, p_ref)
  ON CONFLICT (txn_id, kind) WHERE txn_id IS NOT NULL DO NOTHING;
  IF NOT FOUND THEN RETURN 'already'; END IF;
  -- the payment that was counted stays as received; a new charge for what came back goes on
  IF p_pay IS NOT NULL THEN
    INSERT INTO pap_entries (plan_id, kind, on_date, period, amount, txn_id, inbox_id, ref_entry, note, by_name)
    VALUES (pl.id, CASE p_kind WHEN 'other' THEN 'returned' ELSE p_kind END, v_day, v_per, p_amt, p_txn, p_inbox, p_pay,
            CASE p_kind WHEN 'nsf' THEN 'NSF: the payment of ' || to_char(p_pdate, 'Mon FMDD, YYYY') || ' came back from the bank'
                        WHEN 'chargeback' THEN 'Chargeback: the payment of ' || to_char(p_pdate, 'Mon FMDD, YYYY') || ' was taken back by the customer''s bank'
                        ELSE 'The payment of ' || to_char(p_pdate, 'Mon FMDD, YYYY') || ' came back: ' || coalesce(v_why, 'not approved') END, p_by)
    ON CONFLICT (txn_id, kind) WHERE txn_id IS NOT NULL DO NOTHING;
  END IF;
  IF p_kind = 'nsf' THEN
    SELECT pap_nsf_fee INTO v_fee FROM company_settings LIMIT 1;
    IF coalesce(v_fee, 0) > 0 THEN
      INSERT INTO pap_entries (plan_id, kind, on_date, period, amount, txn_id, inbox_id, note, by_name)
      VALUES (pl.id, 'fee', v_day, v_per, v_fee, p_txn, p_inbox, 'NSF fee for the payment of ' || to_char(p_pdate, 'Mon FMDD, YYYY'), p_by)
      ON CONFLICT (txn_id, kind) WHERE txn_id IS NOT NULL DO NOTHING;
    END IF;
  ELSIF p_kind = 'other' AND pl.status = 'active' THEN
    UPDATE pap_plans SET status = 'paused', pause_why = coalesce(v_why, 'A payment was not approved'), paused_inbox = p_inbox, updated_at = now() WHERE id = pl.id;
  END IF;
  RETURN p_kind;
END $f$;

-- ---------- what the page reads ----------
CREATE OR REPLACE FUNCTION public.pap_pay_home() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET statement_timeout = '60s' AS $f$
DECLARE v jsonb; v_today date := public._pap_today(); v_yr date := date_trunc('year', public._pap_today())::date; v_seen date;
BEGIN
  IF NOT coalesce(public._sec_ok(), false) THEN RETURN NULL; END IF;
  PERFORM public._pap_fill();
  SELECT max(on_date) INTO v_seen FROM pap_entries WHERE kind = 'payment' AND inbox_id IS NOT NULL;   -- the newest draw day on a posted file
  SELECT jsonb_build_object(
    'today', v_today, 'can_post', public._pap_owner(),
    'fee', (SELECT pap_nsf_fee FROM company_settings LIMIT 1),
    'plans', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', p.id, 'customer_id', cu.id, 'name', cu.display_name, 'number', cu.customer_number, 'kind', p.kind, 'label', p.label, 'brand', p.brand,
        'amount', p.amount, 'day', p.draw_day, 'ref', p.reference, 'start', p.start_on, 'months', p.months, 'total', p.total, 'status', p.status,
        'pause_why', p.pause_why, 'end', p.end_on, 'nsf_auto', coalesce(pc.nsf_auto, false),
        'owed', t.owed, 'wait', t.wait, 'paid', t.paid, 'paid_year', t.paid_year, 'last_paid', t.last_paid, 'n_paid', t.n_paid, 'flags', t.flags)
        ORDER BY lower(cu.display_name), p.id)
      FROM pap_plans p
      LEFT JOIN customers cu ON cu.id = public._pap_cust(p.customer_id)
      LEFT JOIN pap_cust pc ON pc.customer_id = cu.id
      CROSS JOIN LATERAL (SELECT coalesce(sum(e.amount) FILTER (WHERE e.kind <> 'payment'), 0) AS owed,
                                 coalesce(sum(e.amount) FILTER (WHERE e.kind = 'payment'), 0) AS paid,
                                 coalesce(sum(e.amount) FILTER (WHERE e.kind = 'payment' AND e.on_date >= v_yr), 0) AS paid_year,
                                 max(e.on_date) FILTER (WHERE e.kind = 'payment') AS last_paid,
                                 count(*) FILTER (WHERE e.kind = 'payment') AS n_paid,
                                 (SELECT count(*) FROM pap_flags g WHERE g.plan_id = p.id AND g.status = 'open') AS flags,
                                 -- a draw that is still on its way: its file has not been posted yet, so it is not counted as owing
                                 coalesce(sum(e.amount) FILTER (WHERE e.kind = 'charge' AND (e.on_date + 10 > v_today OR v_seen IS NULL OR e.on_date > v_seen)
                                    AND NOT EXISTS (SELECT 1 FROM pap_entries y WHERE y.plan_id = p.id AND y.kind = 'payment' AND y.period = e.period)
                                    AND NOT EXISTS (SELECT 1 FROM pap_flags g WHERE g.plan_id = p.id AND date_trunc('month', g.on_date)::date = e.period AND g.kind IN ('nsf', 'chargeback', 'other'))), 0) AS wait
                          FROM pap_entries e WHERE e.plan_id = p.id) t), '[]'::jsonb),
    'files', coalesce((SELECT jsonb_agg(jsonb_build_object('id', i.id, 'file', i.file_name, 'received', i.received_at, 'rows', jsonb_array_length(i.tbl),
        'posted_at', s.posted_at, 'posted_by', s.posted_by, 'counts', s.counts, 'deposit', s.deposit, 'fees', s.fees)
        ORDER BY i.received_at DESC NULLS LAST, i.id DESC)
      FROM pap_inbox i LEFT JOIN pap_settle s ON s.inbox_id = i.id
      WHERE i.tbl IS NOT NULL AND jsonb_typeof(i.tbl) = 'array' AND jsonb_array_length(i.tbl) > 0 AND i.status <> 'ignored'
        AND public._pap_col(i.cols, '^amount$|amount') >= 0 AND public._pap_col(i.cols, 'response|^status$|result|settle') >= 0), '[]'::jsonb),
    'flags', coalesce((SELECT jsonb_agg(x.j ORDER BY x.open DESC, x.at DESC) FROM (
        SELECT (g.status = 'open') AS open, coalesce(g.done_at, g.created_at) AS at, jsonb_build_object(
          'id', g.id, 'kind', g.kind, 'row_kind', g.row_kind, 'plan_id', g.plan_id, 'customer_id', cu.id, 'name', cu.display_name, 'number', cu.customer_number,
          'label', p.label, 'brand', p.brand, 'plan_amount', p.amount, 'plan_status', p.status, 'inbox_id', g.inbox_id, 'file', i.file_name,
          'on', g.on_date, 'ret', g.ret_date, 'amount', g.amount, 'reason', g.reason, 'who', g.who, 'ref', g.ref,
          'status', g.status, 'done_by', g.done_by, 'done_at', g.done_at, 'done_note', g.done_note,
          'notice_at', g.notice_at, 'notice_to', g.notice_to, 'notice_by', g.notice_by, 'nsf_auto', coalesce(pc.nsf_auto, false),
          'fee', (SELECT e.amount FROM pap_entries e WHERE e.txn_id = g.txn_id AND e.kind = 'fee' LIMIT 1),
          'counted', EXISTS (SELECT 1 FROM pap_entries e WHERE e.txn_id = g.txn_id AND e.kind IN ('nsf', 'chargeback', 'returned')),
          'nsf_n', (SELECT count(*) FROM pap_flags z WHERE z.kind = 'nsf' AND z.customer_id = g.customer_id),
          'email', (SELECT k.value FROM customer_contacts k WHERE k.customer_id = cu.id AND k.kind = 'email' ORDER BY k.is_primary DESC, k.id LIMIT 1)) AS j
        FROM pap_flags g
        LEFT JOIN pap_plans p ON p.id = g.plan_id
        LEFT JOIN customers cu ON cu.id = public._pap_cust(coalesce(p.customer_id, g.customer_id))
        LEFT JOIN pap_cust pc ON pc.customer_id = cu.id
        LEFT JOIN pap_inbox i ON i.id = g.inbox_id
        WHERE g.kind <> 'missing' AND (g.status = 'open' OR g.done_at > now() - interval '45 days')) x), '[]'::jsonb),
    -- a draw day that passed more than 10 days ago with no payment and nothing else on a file for that month,
    -- only once a newer file has been posted (so files still waiting to be posted do not look like missed payments)
    'missing', coalesce((SELECT jsonb_agg(jsonb_build_object('plan_id', p.id, 'customer_id', cu.id, 'name', cu.display_name, 'number', cu.customer_number,
          'label', p.label, 'amount', c.amount, 'on', c.on_date, 'period', c.period, 'ref', p.reference) ORDER BY c.on_date DESC, lower(cu.display_name))
      FROM pap_entries c JOIN pap_plans p ON p.id = c.plan_id AND p.status = 'active'
      LEFT JOIN customers cu ON cu.id = public._pap_cust(p.customer_id)
      WHERE c.kind = 'charge' AND c.on_date + 10 <= v_today AND v_seen IS NOT NULL AND c.on_date <= v_seen
        AND c.on_date >= (SELECT min(e.on_date) FROM pap_entries e WHERE e.kind = 'payment' AND e.inbox_id IS NOT NULL)
        AND NOT EXISTS (SELECT 1 FROM pap_entries e WHERE e.plan_id = c.plan_id AND e.kind = 'payment' AND e.period = c.period)
        AND NOT EXISTS (SELECT 1 FROM pap_flags g WHERE g.plan_id = c.plan_id AND date_trunc('month', g.on_date)::date = c.period
                          AND g.kind IN ('nsf', 'chargeback', 'other', 'missing'))), '[]'::jsonb))
  INTO v;
  RETURN v;
END $f$;

-- one plan with its customer and every line of its record
CREATE OR REPLACE FUNCTION public.pap_plan_get(p_id bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v jsonb;
BEGIN
  IF NOT coalesce(public._sec_ok(), false) THEN RETURN NULL; END IF;
  PERFORM public._pap_fill();
  SELECT jsonb_build_object(
    'today', public._pap_today(), 'can_post', public._pap_owner(),
    'seen', (SELECT max(on_date) FROM pap_entries WHERE kind = 'payment' AND inbox_id IS NOT NULL),
    'plan', jsonb_build_object('id', p.id, 'customer_id', cu.id, 'kind', p.kind, 'label', p.label, 'brand', p.brand, 'amount', p.amount, 'day', p.draw_day,
        'ref', p.reference, 'start', p.start_on, 'months', p.months, 'total', p.total, 'invoice_no', p.invoice_no, 'tax_in', p.tax_in, 'status', p.status,
        'pause_why', p.pause_why, 'end', p.end_on, 'note', p.note, 'created_by', p.created_by, 'created_at', p.created_at),
    'customer', jsonb_build_object('id', cu.id, 'name', cu.display_name, 'number', cu.customer_number,
        'nsf_auto', coalesce((SELECT nsf_auto FROM pap_cust WHERE customer_id = cu.id), false),
        'email', (SELECT k.value FROM customer_contacts k WHERE k.customer_id = cu.id AND k.kind = 'email' ORDER BY k.is_primary DESC, k.id LIMIT 1),
        'address', (SELECT jsonb_build_object('street', l.street, 'city', l.city, 'postal', coalesce(to_jsonb(l) ->> 'postal_code', to_jsonb(l) ->> 'zip'))
                    FROM locations l WHERE l.customer_id = cu.id ORDER BY l.active DESC, l.id LIMIT 1)),
    'entries', coalesce((SELECT jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'on', e.on_date, 'period', e.period, 'amount', e.amount,
        'note', e.note, 'by', e.by_name, 'file', e.inbox_id, 'hand', e.inbox_id IS NULL AND e.kind <> 'charge') ORDER BY e.on_date, e.id)
        FROM pap_entries e WHERE e.plan_id = p.id), '[]'::jsonb),
    'flags', coalesce((SELECT jsonb_agg(jsonb_build_object('id', g.id, 'kind', g.kind, 'on', g.on_date, 'amount', g.amount, 'reason', g.reason, 'status', g.status,
        'done_note', g.done_note, 'notice_at', g.notice_at) ORDER BY g.created_at DESC) FROM pap_flags g WHERE g.plan_id = p.id), '[]'::jsonb))
  INTO v
  FROM pap_plans p LEFT JOIN customers cu ON cu.id = public._pap_cust(p.customer_id) WHERE p.id = p_id;
  RETURN v;
END $f$;

-- make a plan, or change one. p: {id?, customer_id, kind, label, brand, amount, day, ref, start (any day of the first month), months, total, invoice_no, tax_in, note}
CREATE OR REPLACE FUNCTION public.pap_plan_save(p jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint := nullif(p ->> 'id', '')::bigint; v_cust bigint := nullif(p ->> 'customer_id', '')::bigint;
        v_kind text := coalesce(nullif(p ->> 'kind', ''), 'service'); v_amt numeric := round(nullif(p ->> 'amount', '')::numeric, 2);
        v_day int := coalesce(nullif(p ->> 'day', '')::int, 7); v_start date := date_trunc('month', coalesce(nullif(p ->> 'start', '')::date, public._pap_today()))::date;
        v_months int := nullif(p ->> 'months', '')::int; v_total numeric := round(nullif(p ->> 'total', '')::numeric, 2);
        v_label text := nullif(btrim(coalesce(p ->> 'label', '')), ''); v_ref text := nullif(btrim(coalesce(p ->> 'ref', '')), ''); o pap_plans;
BEGIN
  IF NOT coalesce(public._sec_ok(), false) THEN RAISE EXCEPTION 'The Security page is not turned on for you'; END IF;
  IF v_label IS NULL THEN RAISE EXCEPTION 'Say what the plan is for'; END IF;
  IF v_kind NOT IN ('service', 'plan') THEN RAISE EXCEPTION 'Pick the kind of plan'; END IF;
  IF coalesce(v_amt, 0) <= 0 THEN RAISE EXCEPTION 'Type the monthly payment'; END IF;
  IF v_day NOT IN (7, 17) THEN RAISE EXCEPTION 'The draw day is the 7th or the 17th'; END IF;
  IF v_kind = 'plan' THEN
    IF coalesce(v_months, 0) < 1 THEN RAISE EXCEPTION 'Type how many months the payment plan runs'; END IF;
    v_total := coalesce(v_total, v_amt * v_months);
    IF v_total <= v_amt * (v_months - 1) OR v_total > v_amt * v_months + 0.005 THEN
      RAISE EXCEPTION 'The total does not fit: % payments of % come to %', v_months, to_char(v_amt, 'FM$999,999,990.00'), to_char(v_amt * v_months, 'FM$999,999,990.00'); END IF;
  ELSE v_months := NULL; v_total := NULL; END IF;
  IF v_id IS NULL THEN
    IF v_cust IS NULL OR NOT EXISTS (SELECT 1 FROM customers WHERE id = v_cust) THEN RAISE EXCEPTION 'Pick the customer'; END IF;
    v_cust := public._pap_cust(v_cust);
    IF v_ref IS NULL THEN SELECT nullif(btrim(customer_number), '') INTO v_ref FROM customers WHERE id = v_cust; END IF;
    INSERT INTO pap_plans (customer_id, kind, label, brand, amount, draw_day, reference, start_on, months, total, invoice_no, tax_in, note, created_by)
    VALUES (v_cust, v_kind, v_label, coalesce(nullif(p ->> 'brand', ''), 'reid'), v_amt, v_day, v_ref, v_start, v_months, v_total,
            nullif(btrim(coalesce(p ->> 'invoice_no', '')), ''), coalesce((p ->> 'tax_in')::boolean, true), nullif(btrim(coalesce(p ->> 'note', '')), ''), public._pap_me())
    RETURNING id INTO v_id;
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
    VALUES ('pap_plans', v_id, 'insert', public.current_app_user_id(), jsonb_build_object('change', 'PAP plan made', 'customer_id', v_cust, 'label', v_label, 'amount', v_amt, 'day', v_day));
  ELSE
    SELECT * INTO o FROM pap_plans WHERE id = v_id;
    IF o.id IS NULL THEN RAISE EXCEPTION 'That plan is gone'; END IF;
    -- the first month and the kind can only change while nothing has been received on the plan
    IF (v_start <> o.start_on OR v_kind <> o.kind) AND EXISTS (SELECT 1 FROM pap_entries WHERE plan_id = v_id AND kind <> 'charge') THEN
      RAISE EXCEPTION 'This plan already has payments on it, so its first month and its kind stay as they are'; END IF;
    UPDATE pap_plans SET kind = v_kind, label = v_label, brand = coalesce(nullif(p ->> 'brand', ''), brand), amount = v_amt, draw_day = v_day, reference = v_ref,
           start_on = v_start, months = v_months, total = v_total, invoice_no = nullif(btrim(coalesce(p ->> 'invoice_no', '')), ''),
           tax_in = coalesce((p ->> 'tax_in')::boolean, tax_in), note = nullif(btrim(coalesce(p ->> 'note', '')), ''), updated_at = now()
    WHERE id = v_id;
    IF v_start <> o.start_on OR v_kind <> o.kind THEN DELETE FROM pap_entries WHERE plan_id = v_id AND kind = 'charge'; END IF;   -- they fill in again from the new first month
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
    VALUES ('pap_plans', v_id, 'update', public.current_app_user_id(), jsonb_build_object('amount', o.amount, 'day', o.draw_day, 'ref', o.reference, 'label', o.label),
            jsonb_build_object('change', 'PAP plan changed', 'amount', v_amt, 'day', v_day, 'ref', v_ref, 'label', v_label));
  END IF;
  PERFORM public._pap_fill();
  RETURN v_id;
END $f$;

-- active / paused (with why) / ended (no more monthly charges after this month)
CREATE OR REPLACE FUNCTION public.pap_plan_status(p_id bigint, p_status text, p_why text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT coalesce(public._sec_ok(), false) THEN RAISE EXCEPTION 'The Security page is not turned on for you'; END IF;
  IF p_status NOT IN ('active', 'paused', 'ended') THEN RAISE EXCEPTION 'Unknown status'; END IF;
  UPDATE pap_plans SET status = p_status, pause_why = CASE WHEN p_status = 'paused' THEN nullif(btrim(coalesce(p_why, '')), '') END,
         paused_inbox = NULL, end_on = CASE WHEN p_status = 'ended' THEN date_trunc('month', public._pap_today())::date END, updated_at = now()
  WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That plan is gone'; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pap_plans', p_id, 'update', public.current_app_user_id(), jsonb_build_object('change', 'PAP plan ' || p_status, 'why', p_why));
END $f$;

-- a plan made by mistake: only while nothing has been received on it (owners)
CREATE OR REPLACE FUNCTION public.pap_plan_delete(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE o pap_plans;
BEGIN
  IF NOT public._pap_owner() THEN RAISE EXCEPTION 'Only owners can delete a plan'; END IF;
  SELECT * INTO o FROM pap_plans WHERE id = p_id;
  IF o.id IS NULL THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM pap_entries WHERE plan_id = p_id AND kind <> 'charge') OR EXISTS (SELECT 1 FROM pap_flags WHERE plan_id = p_id) THEN
    RAISE EXCEPTION 'This plan has payments or problems on it. End it instead: its record is kept.'; END IF;
  DELETE FROM pap_plans WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values)
  VALUES ('pap_plans', p_id, 'delete', public.current_app_user_id(), to_jsonb(o));
END $f$;

-- a line put on by hand: a payment received another way (cheque, e-transfer), a fee, or a change (a minus is a credit)
CREATE OR REPLACE FUNCTION public.pap_entry_add(p_plan bigint, p_kind text, p_amount numeric, p_on date, p_note text) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_id bigint; v_on date := coalesce(p_on, public._pap_today());
BEGIN
  IF NOT coalesce(public._sec_ok(), false) THEN RAISE EXCEPTION 'The Security page is not turned on for you'; END IF;
  IF p_kind NOT IN ('payment', 'fee', 'adjust') THEN RAISE EXCEPTION 'Pick what the line is'; END IF;
  IF coalesce(p_amount, 0) = 0 OR (p_kind <> 'adjust' AND p_amount < 0) THEN RAISE EXCEPTION 'Type the amount'; END IF;
  IF nullif(btrim(coalesce(p_note, '')), '') IS NULL THEN RAISE EXCEPTION 'Say what it is for'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pap_plans WHERE id = p_plan) THEN RAISE EXCEPTION 'That plan is gone'; END IF;
  INSERT INTO pap_entries (plan_id, kind, on_date, period, amount, note, by_name)
  VALUES (p_plan, p_kind, v_on, date_trunc('month', v_on)::date, round(p_amount, 2), btrim(p_note), public._pap_me()) RETURNING id INTO v_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pap_entries', v_id, 'insert', public.current_app_user_id(), jsonb_build_object('change', 'PAP line added by hand', 'plan', p_plan, 'kind', p_kind, 'amount', p_amount, 'note', p_note));
  RETURN v_id;
END $f$;

-- take off a line that was put on by hand (owners). Lines from a settlement file come off with "Undo" on the file.
CREATE OR REPLACE FUNCTION public.pap_entry_del(p_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE o pap_entries;
BEGIN
  IF NOT public._pap_owner() THEN RAISE EXCEPTION 'Only owners can take a line off'; END IF;
  SELECT * INTO o FROM pap_entries WHERE id = p_id;
  IF o.id IS NULL THEN RETURN; END IF;
  IF o.inbox_id IS NOT NULL OR o.kind = 'charge' THEN RAISE EXCEPTION 'This line was not put on by hand'; END IF;
  DELETE FROM pap_entries WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values)
  VALUES ('pap_entries', p_id, 'delete', public.current_app_user_id(), to_jsonb(o));
END $f$;

-- ---------- a settlement file: look at it, post it, undo it ----------
CREATE OR REPLACE FUNCTION public.pap_settle_view(p_inbox bigint, p_kinds jsonb DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET statement_timeout = '90s' AS $f$
DECLARE v jsonb; f pap_inbox; s pap_settle;
BEGIN
  IF NOT coalesce(public._sec_ok(), false) THEN RETURN NULL; END IF;
  SELECT * INTO f FROM pap_inbox WHERE id = p_inbox;
  IF f.id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO s FROM pap_settle WHERE inbox_id = p_inbox;
  SELECT jsonb_build_object('id', f.id, 'file', f.file_name, 'received', f.received_at, 'can_post', public._pap_owner(),
      'posted_at', s.posted_at, 'posted_by', s.posted_by, 'deposit', s.deposit, 'fees', s.fees,
      'fee', (SELECT pap_nsf_fee FROM company_settings LIMIT 1),
      'rows', coalesce(jsonb_agg(jsonb_build_object('i', r.i, 'txn', r.txn, 'on', r.pdate, 'ret', r.rdate, 'type', r.typ, 'resp', r.resp, 'settled', r.setl,
          'amount', r.amt, 'ref', r.ref, 'who', r.who, 'kind', r.kind, 'read', r.read_kind, 'plan_id', r.plan_id, 'how', r.how,
          'customer_id', r.customer_id, 'name', cu.display_name, 'number', cu.customer_number, 'label', p.label, 'plan_amount', p.amount,
          'already', r.already, 'counted', r.pay_entry IS NOT NULL) ORDER BY r.i), '[]'::jsonb))
  INTO v
  FROM public._pap_settle_rows(p_inbox, coalesce(p_kinds, s.kinds)) r
  LEFT JOIN pap_plans p ON p.id = r.plan_id
  LEFT JOIN customers cu ON cu.id = r.customer_id;
  RETURN coalesce(v, jsonb_build_object('id', f.id, 'file', f.file_name, 'rows', '[]'::jsonb));
END $f$;

CREATE OR REPLACE FUNCTION public.pap_settle_post(p_inbox bigint, p_kinds jsonb DEFAULT NULL, p_deposit numeric DEFAULT NULL, p_fees numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET statement_timeout = '120s' AS $f$
DECLARE r record; v_by text := public._pap_me(); v_res text; n_pay int := 0; n_nsf int := 0; n_cb int := 0; n_oth int := 0; n_nop int := 0; n_had int := 0; n_skip int := 0;
        t_pay numeric := 0; t_ret numeric := 0; v_counts jsonb;
BEGIN
  IF NOT public._pap_owner() THEN RAISE EXCEPTION 'Only an owner can post a settlement file'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pap_inbox WHERE id = p_inbox AND tbl IS NOT NULL) THEN RAISE EXCEPTION 'That file can not be read'; END IF;
  PERFORM pg_advisory_xact_lock(7306, p_inbox::int);
  FOR r IN SELECT * FROM public._pap_settle_rows(p_inbox, p_kinds) LOOP
    IF r.kind = 'skip' THEN n_skip := n_skip + 1; CONTINUE; END IF;
    IF r.already THEN n_had := n_had + 1; CONTINUE; END IF;
    IF r.plan_id IS NULL THEN
      INSERT INTO pap_flags (kind, row_kind, customer_id, inbox_id, txn_id, on_date, ret_date, amount, reason, who, ref)
      VALUES ('noplan', r.kind, r.customer_id, p_inbox, r.txn, r.pdate, r.rdate, r.amt,
              CASE r.how WHEN 'several' THEN 'This customer has more than one plan and I can not tell which one this is for'
                         WHEN 'no plan' THEN 'This customer has no PAP plan yet' ELSE 'I could not find the customer for this row' END
                || CASE WHEN r.kind <> 'paid' THEN '. The file says: ' || coalesce(nullif(r.resp, ''), nullif(r.setl, ''), 'not approved') ELSE '' END, r.who, r.ref)
      ON CONFLICT (txn_id, kind) WHERE txn_id IS NOT NULL DO NOTHING;
      IF FOUND THEN n_nop := n_nop + 1; ELSE n_had := n_had + 1; END IF;
      CONTINUE;
    END IF;
    v_res := public._pap_post_row(r.plan_id, r.kind, r.txn, r.pdate, r.rdate, r.amt, r.ref, r.who, coalesce(nullif(r.resp, ''), nullif(r.setl, '')), p_inbox, r.pay_entry, v_by);
    IF v_res = 'payment' THEN n_pay := n_pay + 1; t_pay := t_pay + r.amt;
    ELSIF v_res = 'nsf' THEN n_nsf := n_nsf + 1; t_ret := t_ret + r.amt;
    ELSIF v_res = 'chargeback' THEN n_cb := n_cb + 1; t_ret := t_ret + r.amt;
    ELSIF v_res = 'other' THEN n_oth := n_oth + 1; t_ret := t_ret + r.amt;
    ELSIF v_res = 'already' THEN n_had := n_had + 1; ELSE n_skip := n_skip + 1; END IF;
  END LOOP;
  v_counts := jsonb_build_object('payments', n_pay, 'paid', t_pay, 'nsf', n_nsf, 'chargebacks', n_cb, 'other', n_oth, 'returned', t_ret, 'no_plan', n_nop, 'already', n_had, 'skipped', n_skip);
  INSERT INTO pap_settle (inbox_id, posted_by, deposit, fees, counts, kinds) VALUES (p_inbox, v_by, p_deposit, p_fees, v_counts, p_kinds)
  ON CONFLICT (inbox_id) DO UPDATE SET posted_at = now(), posted_by = EXCLUDED.posted_by, deposit = coalesce(EXCLUDED.deposit, pap_settle.deposit),
     fees = coalesce(EXCLUDED.fees, pap_settle.fees), kinds = coalesce(EXCLUDED.kinds, pap_settle.kinds),
     counts = jsonb_build_object('payments', coalesce((pap_settle.counts ->> 'payments')::int, 0) + n_pay, 'paid', coalesce((pap_settle.counts ->> 'paid')::numeric, 0) + t_pay,
        'nsf', coalesce((pap_settle.counts ->> 'nsf')::int, 0) + n_nsf, 'chargebacks', coalesce((pap_settle.counts ->> 'chargebacks')::int, 0) + n_cb,
        'other', coalesce((pap_settle.counts ->> 'other')::int, 0) + n_oth, 'returned', coalesce((pap_settle.counts ->> 'returned')::numeric, 0) + t_ret,
        'no_plan', coalesce((pap_settle.counts ->> 'no_plan')::int, 0) + n_nop, 'already', n_had, 'skipped', n_skip);
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pap_settle', p_inbox, 'update', public.current_app_user_id(), jsonb_build_object('change', 'EFT settlement file posted') || v_counts);
  RETURN v_counts;
END $f$;

-- take back everything a file put on: its payments, charges, fees and flags; a plan it paused goes back to active (owners)
CREATE OR REPLACE FUNCTION public.pap_settle_undo(p_inbox bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE n_e int; n_f int;
BEGIN
  IF NOT public._pap_owner() THEN RAISE EXCEPTION 'Only an owner can undo a posted file'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pap_settle WHERE inbox_id = p_inbox) THEN RAISE EXCEPTION 'That file is not posted'; END IF;
  IF EXISTS (SELECT 1 FROM pap_entries z JOIN pap_entries e ON e.id = z.ref_entry WHERE e.inbox_id = p_inbox AND z.inbox_id IS DISTINCT FROM p_inbox) THEN
    RAISE EXCEPTION 'A newer file has an NSF or chargeback for a payment on this file. Undo that newer file first.'; END IF;
  DELETE FROM pap_entries WHERE inbox_id = p_inbox; GET DIAGNOSTICS n_e = ROW_COUNT;
  DELETE FROM pap_flags WHERE inbox_id = p_inbox; GET DIAGNOSTICS n_f = ROW_COUNT;
  UPDATE pap_plans SET status = 'active', pause_why = NULL, paused_inbox = NULL, updated_at = now() WHERE paused_inbox = p_inbox AND status = 'paused';
  DELETE FROM pap_settle WHERE inbox_id = p_inbox;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pap_settle', p_inbox, 'update', public.current_app_user_id(), jsonb_build_object('change', 'EFT settlement file posting undone', 'lines', n_e, 'flags', n_f));
  RETURN jsonb_build_object('lines', n_e, 'flags', n_f);
END $f$;

-- ---------- the follow-up list ----------
CREATE OR REPLACE FUNCTION public.pap_flag_done(p_id bigint, p_note text DEFAULT NULL, p_done boolean DEFAULT true) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT coalesce(public._sec_ok(), false) THEN RAISE EXCEPTION 'The Security page is not turned on for you'; END IF;
  UPDATE pap_flags SET status = CASE WHEN p_done THEN 'done' ELSE 'open' END, done_by = CASE WHEN p_done THEN public._pap_me() END,
         done_at = CASE WHEN p_done THEN now() END, done_note = CASE WHEN p_done THEN nullif(btrim(coalesce(p_note, '')), '') END
  WHERE id = p_id;
END $f$;

-- a missed payment (worked out, not from a file) that someone has looked after
CREATE OR REPLACE FUNCTION public.pap_missing_done(p_plan bigint, p_on date, p_note text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT coalesce(public._sec_ok(), false) THEN RAISE EXCEPTION 'The Security page is not turned on for you'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pap_plans WHERE id = p_plan) THEN RAISE EXCEPTION 'That plan is gone'; END IF;
  INSERT INTO pap_flags (kind, plan_id, customer_id, on_date, reason, status, done_by, done_at, done_note)
  SELECT 'missing', p.id, public._pap_cust(p.customer_id), p_on, 'No payment was on a settlement file for this draw day', 'done', public._pap_me(), now(), nullif(btrim(coalesce(p_note, '')), '')
  FROM pap_plans p WHERE p.id = p_plan;
END $f$;

-- the NSF notice went out (the app's own email); who it went to is kept on the flag
CREATE OR REPLACE FUNCTION public.pap_flag_notice(p_id bigint, p_to text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT coalesce(public._sec_ok(), false) THEN RAISE EXCEPTION 'The Security page is not turned on for you'; END IF;
  UPDATE pap_flags SET notice_at = now(), notice_to = nullif(btrim(coalesce(p_to, '')), ''), notice_by = public._pap_me() WHERE id = p_id;
END $f$;

-- a row that had no plan: put it on the plan it belongs to (and remember its reference when the plan has none)
CREATE OR REPLACE FUNCTION public.pap_flag_post(p_id bigint, p_plan bigint) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE g pap_flags; v_res text; v_pay bigint;
BEGIN
  IF NOT public._pap_owner() THEN RAISE EXCEPTION 'Only an owner can post a payment'; END IF;
  SELECT * INTO g FROM pap_flags WHERE id = p_id;
  IF g.id IS NULL OR g.kind <> 'noplan' THEN RAISE EXCEPTION 'That row is gone'; END IF;
  IF g.status = 'done' THEN RAISE EXCEPTION 'That row was already looked after'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pap_plans WHERE id = p_plan) THEN RAISE EXCEPTION 'Pick the plan'; END IF;
  IF coalesce(g.row_kind, 'paid') <> 'paid' THEN
    SELECT e.id INTO v_pay FROM pap_entries e WHERE e.kind = 'payment' AND (e.txn_id = g.txn_id OR (e.plan_id = p_plan AND e.on_date = g.on_date AND e.amount = g.amount
       AND NOT EXISTS (SELECT 1 FROM pap_entries z WHERE z.ref_entry = e.id))) ORDER BY (e.txn_id = g.txn_id) DESC, e.id LIMIT 1;
  END IF;
  v_res := public._pap_post_row(p_plan, coalesce(g.row_kind, 'paid'), g.txn_id, g.on_date, g.ret_date, g.amount, g.ref, g.who,
                                nullif(substring(g.reason from 'The file says: (.*)$'), ''), g.inbox_id, v_pay, public._pap_me());
  UPDATE pap_plans SET reference = g.ref, updated_at = now() WHERE id = p_plan AND nullif(btrim(coalesce(reference, '')), '') IS NULL AND nullif(btrim(coalesce(g.ref, '')), '') IS NOT NULL;
  UPDATE pap_flags SET status = 'done', done_by = public._pap_me(), done_at = now(), done_note = 'Put on the plan', plan_id = p_plan WHERE id = p_id;
  RETURN v_res;
END $f$;

-- send this customer the NSF notice by itself from now on (or stop)
CREATE OR REPLACE FUNCTION public.pap_nsf_auto_set(p_customer bigint, p_on boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT coalesce(public._sec_ok(), false) THEN RAISE EXCEPTION 'The Security page is not turned on for you'; END IF;
  INSERT INTO pap_cust (customer_id, nsf_auto, set_by) VALUES (public._pap_cust(p_customer), coalesce(p_on, false), public._pap_me())
  ON CONFLICT (customer_id) DO UPDATE SET nsf_auto = EXCLUDED.nsf_auto, set_by = EXCLUDED.set_by, set_at = now();
END $f$;

CREATE OR REPLACE FUNCTION public.pap_fee_set(p_fee numeric) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  IF NOT public._pap_owner() THEN RAISE EXCEPTION 'Only an owner can set the NSF fee'; END IF;
  IF p_fee IS NOT NULL AND (p_fee < 0 OR p_fee > 500) THEN RAISE EXCEPTION 'That fee does not look right'; END IF;
  UPDATE company_settings SET pap_nsf_fee = round(p_fee, 2) WHERE true;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('company_settings', 0, 'update', public.current_app_user_id(), jsonb_build_object('change', 'NSF fee for PAP plans', 'fee', p_fee));
END $f$;

-- the first set-up: one plan for each customer on a settlement file who has none yet (owners). Each plan takes its amount, its draw day
-- (the 7th or the 17th, from the file's date), its first month and its reference from the file. A customer with more than one row is left for a person.
CREATE OR REPLACE FUNCTION public.pap_plans_from_file(p_inbox bigint, p_label text, p_brand text DEFAULT 'reid', p_dry boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET statement_timeout = '120s' AS $f$
DECLARE r record; n int := 0; n_skip int := 0; v_label text := nullif(btrim(coalesce(p_label, '')), ''); v_by text := public._pap_me();
BEGIN
  IF NOT public._pap_owner() THEN RAISE EXCEPTION 'Only an owner can make the plans from a file'; END IF;
  IF v_label IS NULL AND NOT p_dry THEN RAISE EXCEPTION 'Say what the plans are for'; END IF;
  IF coalesce(p_brand, 'reid') NOT IN ('reid', 'accurate', 'hsg') THEN RAISE EXCEPTION 'Pick the business'; END IF;
  FOR r IN
    SELECT x.customer_id, (array_agg(x.amt))[1] AS amt, (array_agg(x.pdate))[1] AS pdate, (array_agg(x.ref))[1] AS ref, count(*) AS rows_n
    FROM public._pap_settle_rows(p_inbox, NULL) x
    WHERE x.how = 'no plan' AND x.kind = 'paid' AND x.customer_id IS NOT NULL AND x.amt > 0
    GROUP BY x.customer_id
  LOOP
    IF r.rows_n > 1 OR EXISTS (SELECT 1 FROM pap_plans p WHERE public._pap_cust(p.customer_id) = r.customer_id AND p.status <> 'ended') THEN n_skip := n_skip + 1; CONTINUE; END IF;
    n := n + 1;
    IF NOT p_dry THEN
      INSERT INTO pap_plans (customer_id, kind, label, brand, amount, draw_day, reference, start_on, created_by, note)
      VALUES (r.customer_id, 'service', v_label, coalesce(p_brand, 'reid'), r.amt, CASE WHEN extract(day FROM r.pdate) < 12 THEN 7 ELSE 17 END,
              coalesce(nullif(btrim(r.ref), ''), (SELECT nullif(btrim(customer_number), '') FROM customers WHERE id = r.customer_id)),
              date_trunc('month', r.pdate)::date, v_by, 'Made from the settlement file of ' || to_char(r.pdate, 'Mon FMDD, YYYY'));
    END IF;
  END LOOP;
  IF NOT p_dry AND n > 0 THEN
    PERFORM public._pap_fill();
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
    VALUES ('pap_plans', 0, 'insert', public.current_app_user_id(), jsonb_build_object('change', 'PAP plans made from a settlement file', 'file', p_inbox, 'plans', n, 'label', v_label));
  END IF;
  RETURN jsonb_build_object('plans', n, 'left', n_skip);
END $f$;

REVOKE EXECUTE ON FUNCTION public._pap_owner(), public._pap_me(), public._pap_fill(), public._pap_cust(bigint), public._pap_settle_rows(bigint, jsonb),
  public._pap_post_row(bigint, text, text, date, date, numeric, text, text, text, bigint, bigint, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.pap_pay_home(), public.pap_plan_get(bigint), public.pap_plan_save(jsonb), public.pap_plan_status(bigint, text, text),
  public.pap_plan_delete(bigint), public.pap_entry_add(bigint, text, numeric, date, text), public.pap_entry_del(bigint),
  public.pap_settle_view(bigint, jsonb), public.pap_settle_post(bigint, jsonb, numeric, numeric), public.pap_settle_undo(bigint),
  public.pap_flag_done(bigint, text, boolean), public.pap_missing_done(bigint, date, text), public.pap_flag_notice(bigint, text),
  public.pap_flag_post(bigint, bigint), public.pap_nsf_auto_set(bigint, boolean), public.pap_fee_set(numeric),
  public.pap_plans_from_file(bigint, text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_pay_home(), public.pap_plan_get(bigint), public.pap_plan_save(jsonb), public.pap_plan_status(bigint, text, text),
  public.pap_plan_delete(bigint), public.pap_entry_add(bigint, text, numeric, date, text), public.pap_entry_del(bigint),
  public.pap_settle_view(bigint, jsonb), public.pap_settle_post(bigint, jsonb, numeric, numeric), public.pap_settle_undo(bigint),
  public.pap_flag_done(bigint, text, boolean), public.pap_missing_done(bigint, date, text), public.pap_flag_notice(bigint, text),
  public.pap_flag_post(bigint, bigint), public.pap_nsf_auto_set(bigint, boolean), public.pap_fee_set(numeric),
  public.pap_plans_from_file(bigint, text, text, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';

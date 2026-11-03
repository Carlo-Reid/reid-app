-- Bank payment matching: payments added together into one deposit must be from the same day or the day after (fewer chance matches)
DO $do$
DECLARE src text := pg_get_functiondef('public.bank_pay_match(text, integer)'::regprocedure);
BEGIN
  IF src LIKE '%abs(a.dt - b.dt) <= 1%' THEN RETURN; END IF;
  src := replace(src, 'JOIN c b ON a.id < b.id AND abs(a.amt + b.amt - d.amt) < 0.01', 'JOIN c b ON a.id < b.id AND abs(a.dt - b.dt) <= 1 AND abs(a.amt + b.amt - d.amt) < 0.01');
  src := replace(src, 'JOIN c b ON a.id < b.id JOIN c e ON b.id < e.id AND abs(a.amt + b.amt + e.amt - d.amt) < 0.01', 'JOIN c b ON a.id < b.id AND abs(a.dt - b.dt) <= 1 JOIN c e ON b.id < e.id AND abs(a.dt - e.dt) <= 1 AND abs(b.dt - e.dt) <= 1 AND abs(a.amt + b.amt + e.amt - d.amt) < 0.01');
  IF src NOT LIKE '%abs(a.dt - e.dt) <= 1%' THEN RAISE EXCEPTION 'bank_pay_match: anchors not found'; END IF;
  EXECUTE src;
END $do$;

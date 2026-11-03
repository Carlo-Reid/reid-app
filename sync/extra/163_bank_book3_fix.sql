-- One-time fix: Book3.xlsx (Main account, Sep 22 – Nov 3 2026) was loaded with its columns shifted (that file has no Code column):
-- the description went into Code, the withdrawal into Description, the deposit into Out and the balance (without its sign) into In.
-- Put each back in its place; the balance's sign comes from checking it against the next line. Lines the earlier file already had
-- (the overlapping days) are taken out so they aren't in twice. Only touches lines still shifted, so it's safe to run more than once.
DO $$
DECLARE neg int; pos int; sgn int;
BEGIN
  CREATE TEMP TABLE _b3 ON COMMIT DROP AS
    SELECT id, txn_date, code AS d,
           abs(coalesce(nullif(regexp_replace(description, '[^0-9.]', '', 'g'), '')::numeric, 0)) AS o,
           amount_out AS i, amount_in AS b
    FROM bank_transactions
    WHERE file_name = 'Book3.xlsx' AND account = 'main' AND code <> '' AND description ~ '^\s*[-(]?\$?[0-9,]*\.?[0-9]*\)?\s*$';
  IF NOT EXISTS (SELECT 1 FROM _b3) THEN RETURN; END IF;
  -- which sign makes each balance follow from the next line (the file lists newest first)
  SELECT count(*) FILTER (WHERE abs(-a.b - (-n.b + a.i - a.o)) < 0.02), count(*) FILTER (WHERE abs(a.b - (n.b + a.i - a.o)) < 0.02)
    INTO neg, pos FROM _b3 a JOIN _b3 n ON n.id = (SELECT min(id) FROM _b3 WHERE id > a.id);
  sgn := CASE WHEN neg > pos THEN -1 ELSE 1 END;
  RAISE NOTICE 'Book3 fix: % lines, balance sign % (neg % / pos %)', (SELECT count(*) FROM _b3), sgn, neg, pos;
  -- the overlapping days: the earlier file already has these lines
  DELETE FROM bank_transactions t USING _b3 x
   WHERE t.id = x.id AND EXISTS (SELECT 1 FROM bank_transactions e WHERE e.account = 'main' AND e.id <> x.id AND coalesce(e.file_name, '') <> 'Book3.xlsx'
                                   AND e.txn_date = x.txn_date AND e.description = btrim(x.d) AND e.amount_out = x.o AND e.amount_in = x.i);
  -- the same line twice in the file after the fix: keep one
  DELETE FROM bank_transactions t USING _b3 x
   WHERE t.id = x.id AND EXISTS (SELECT 1 FROM _b3 y WHERE y.id < x.id AND y.txn_date = x.txn_date AND y.d = x.d AND y.o = x.o AND y.i = x.i AND y.b = x.b);
  UPDATE bank_transactions t SET code = '', description = btrim(x.d), amount_out = x.o, amount_in = x.i, balance = sgn * x.b
    FROM _b3 x WHERE t.id = x.id;
END $$;

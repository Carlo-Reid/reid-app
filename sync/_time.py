import sys, time
sys.path.insert(0, "sync"); import eft_mail as m
db = m.connect_db(); cur = db.cursor(); cur.execute("SET statement_timeout = '120s'")
cur.execute(open("sync/_pairs.sql", encoding="utf-8").read())
cur.execute("SELECT count(*) FROM pg_indexes WHERE tablename = 'invoices'"); print(f"::notice::invoice indexes: {cur.fetchone()[0]}", flush=True)
cur.execute("SELECT string_agg(indexname, ',') FROM pg_indexes WHERE tablename = 'invoices'"); print(f"::notice::{cur.fetchone()[0][:900]}", flush=True)
for fn in ("pairs_a", "pairs_b"):
    for v in ("523.45", "33.90"):
        t = time.time(); cur.execute(f"SELECT pg_temp.{fn}(%s::numeric, 'total')", (v,)); r = cur.fetchone()[0]; dt = time.time() - t
        print(f"::notice::{fn} {v}: {dt:.2f}s -> {str(r)[:60] if fn == 'pairs_b' else (r or {}).get('n')}", flush=True)
cur.execute("EXPLAIN ANALYZE SELECT pg_temp.pairs_b(523.45, 'total')")

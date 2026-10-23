import os, sys, time, json
sys.path.insert(0, "sync"); import eft_mail as m
db = m.connect_db(); cur = db.cursor()
cur.execute("SET statement_timeout = '180s'")
cur.execute(open("sync/_match_t.sql", encoding="utf-8").read())
cur.execute("SELECT count(*) FROM customers"); nc = cur.fetchone()[0]
cur.execute("SELECT count(*) FROM locations"); nl = cur.fetchone()[0]
cur.execute("SELECT id, rows FROM pap_inbox WHERE rows IS NOT NULL ORDER BY id")
for iid, rows in cur.fetchall():
    p = json.dumps([{"i": k + 1, "num": r[0], "name": r[1], "phone": r[2]} for k, r in enumerate(rows)])
    t = time.time(); cur.execute("SELECT how, count(*) FROM pg_temp.pap_match_t(%s::jsonb) GROUP BY how", (p,)); res = cur.fetchall(); dt = time.time() - t
    print(f"::notice::list {iid}: {len(rows)} rows matched in {dt:.1f}s: {dict(res)} (customers {nc}, locations {nl})", flush=True)

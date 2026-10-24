import os, psycopg
c = psycopg.connect(host=os.environ["DB_HOST"], port=int(os.environ["DB_PORT"]), dbname=os.environ["DB_NAME"], user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"])
c.execute("SET default_transaction_read_only = on")
out = []
for t, cols in c.execute("""SELECT table_name, string_agg(column_name || ' ' || data_type || coalesce(' =' || column_default, ''), ', ' ORDER BY ordinal_position)
  FROM information_schema.columns WHERE table_schema = 'public' GROUP BY table_name ORDER BY table_name"""):
    out.append(f"TABLE {t}: {cols}")
for (n,) in c.execute("SELECT extname || ' ' || extversion FROM pg_extension"): out.append("EXT " + n)
for (n,) in c.execute("SELECT name FROM pg_available_extensions WHERE name IN ('pg_cron','pg_net','http')"): out.append("AVAIL " + n)
for (n, cnt) in c.execute("""SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE schemaname='public' ORDER BY relname"""): out.append(f"ROWS {n} {cnt}")
for (d,) in c.execute("""SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f' ORDER BY p.proname"""):
    out.append("FUNC " + d)
for q in ["SELECT status, count(*) FROM estimates GROUP BY 1", "SELECT status, count(*) FROM invoices GROUP BY 1", "SELECT name FROM business_units ORDER BY 1",
          "SELECT code FROM permissions ORDER BY 1", "SELECT list, count(*) FROM followups GROUP BY 1"]:
    try: out.append("Q " + q + " => " + repr(c.execute(q).fetchall()))
    except Exception as e: c.rollback(); c.execute("SET default_transaction_read_only = on"); out.append("Q " + q + " ERR " + str(e)[:200])
open("schema.txt", "w").write("\n".join(out))
print(len(out), "lines")

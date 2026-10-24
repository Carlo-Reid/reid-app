import sys, re
sys.path.insert(0, "sync"); import eft_mail as m
db = m.connect_db(); db.autocommit = True; cur = db.cursor()
out = []
cur.execute("""SELECT query, round(mean_exec_time)::int, calls FROM pg_stat_statements WHERE calls > 20 AND query ILIKE '%pgrst%' ORDER BY mean_exec_time * calls DESC LIMIT 8""")
for qtext, ms, calls in cur.fetchall():
    fn = re.findall(r'"public"\."([a-z_0-9]+)"', qtext)
    out.append(f"{','.join(dict.fromkeys(fn))[:60]}={ms}ms x{calls}")
print("::notice::slow app calls: " + " | ".join(out), flush=True)
cur.execute("""SELECT string_agg(p.proname, ', ' ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = 'public' AND p.prosecdef AND has_function_privilege('anon', p.oid, 'EXECUTE')""")
print("::notice::secure functions anon can run: " + str(cur.fetchone()[0])[:3500], flush=True)
cur.execute("""SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.prosecdef AND has_function_privilege('anon', p.oid, 'EXECUTE')""")
print("::notice::count: " + str(cur.fetchone()[0]), flush=True)
cur.execute("SELECT left(prosrc, 400) FROM pg_proc WHERE proname = '_sync_after' LIMIT 1")
r = cur.fetchone(); print("::notice::_sync_after starts: " + (r[0].replace(chr(10), ' ')[:400] if r else "none"), flush=True)

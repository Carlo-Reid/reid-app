import sys
sys.path.insert(0, "sync"); import eft_mail as m
db = m.connect_db(); db.autocommit = True; cur = db.cursor()
for fn in ["postal_zone_list", "town_list", "community_list", "neighbourhood_list", "pb_categories", "customer_dupe_hint"]:
    cur.execute("SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = %s ORDER BY p.oid DESC LIMIT 1", (fn,))
    r = cur.fetchone(); d = (r[0] if r else "none").replace("\n", " ⏎ ")
    print(f"::notice::{fn}: {d[:3900]}", flush=True)
cur.execute("SELECT string_agg(indexname || '(' || tablename || ')', ', ') FROM pg_indexes WHERE schemaname='public' AND tablename IN ('locations','customers','neighbourhoods','communities','postal_zones','towns','pricebook_categories','pricebook_items')")
print("::notice::indexes: " + str(cur.fetchone()[0])[:3900], flush=True)

import sys
sys.path.insert(0, "sync"); import eft_mail as m
db = m.connect_db(); db.autocommit = True; cur = db.cursor()
def q(label, sql):
    try:
        cur.execute(sql); print(f"::notice::{label}: {cur.fetchall()}", flush=True)
    except Exception as e:
        print(f"::notice::{label}: ERROR {str(e)[:150]}", flush=True)
q("tables", "SELECT string_agg(table_name, ',' ORDER BY table_name) FROM information_schema.tables WHERE table_schema='public' AND (table_name ILIKE '%monitor%' OR table_name ILIKE '%member%' OR table_name ILIKE '%secur%' OR table_name ILIKE '%alarm%' OR table_name ILIKE '%business_unit%' OR table_name ILIKE '%agreement%' OR table_name ILIKE '%contract%')")
q("monitoring_contracts", "SELECT count(*), count(DISTINCT customer_id) FROM monitoring_contracts")
q("business units", "SELECT string_agg(name || '=' || id, ' | ') FROM business_units")
q("customers with security jobs", "SELECT count(DISTINCT j.customer_id) FROM jobs j JOIN business_units b ON b.id = j.business_unit_id WHERE b.name ILIKE '%secur%'")
q("customers with security invoices", "SELECT count(DISTINCT i.customer_id) FROM invoices i JOIN business_units b ON b.id = i.business_unit_id WHERE b.name ILIKE '%secur%'")
q("membership types", "SELECT string_agg(DISTINCT coalesce(to_jsonb(t) ->> 'name', '?'), ' | ') FROM membership_types t")
q("memberships cols", "SELECT string_agg(column_name, ',') FROM information_schema.columns WHERE table_name = 'memberships'")
q("customers cols", "SELECT string_agg(column_name, ',') FROM information_schema.columns WHERE table_name = 'customers'")
q("security memberships", "SELECT count(DISTINCT m.customer_id) FROM memberships m JOIN membership_types t ON t.id = m.membership_type_id WHERE (to_jsonb(t) ->> 'name') ILIKE '%secur%' OR (to_jsonb(t) ->> 'name') ILIKE '%monitor%' OR (to_jsonb(t) ->> 'name') ILIKE '%alarm%'")
q("job types security", "SELECT string_agg(name || ':' || n, ' | ') FROM (SELECT t.name, count(DISTINCT j.customer_id) n FROM jobs j JOIN job_types t ON t.id = j.job_type_id WHERE t.job_class = 'security' OR t.name ILIKE '%secur%' OR t.name ILIKE '%alarm%' OR t.name ILIKE '%monitor%' GROUP BY 1 ORDER BY 2 DESC LIMIT 12) x")

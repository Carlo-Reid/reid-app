import sys
sys.path.insert(0, "sync"); import eft_mail as m
db = m.connect_db(); db.autocommit = True; cur = db.cursor()
def q(label, sql):
    try:
        cur.execute(sql); rows = cur.fetchall(); txt = str(rows)[:1800]
    except Exception as e:
        txt = "ERROR " + str(e)[:200]
    print(f"::notice::{label}: {txt}", flush=True)
q("1 tables without row security", "SELECT string_agg(c.relname, ', ' ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relrowsecurity")
q("2 tables anon or authenticated can read directly", "SELECT string_agg(DISTINCT table_name || ':' || grantee, ', ') FROM information_schema.role_table_grants WHERE table_schema = 'public' AND grantee IN ('anon') AND privilege_type = 'SELECT'")
q("3 functions anyone (anon) can run", "SELECT count(*), string_agg(p.proname, ', ' ORDER BY p.proname) FILTER (WHERE p.prosecdef) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND has_function_privilege('anon', p.oid, 'EXECUTE')")
q("4 owner-only/permission functions that may let a NULL through", "SELECT count(*), string_agg(p.proname, ', ' ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.prosecdef AND p.prosrc ~ 'CASE WHEN NOT public\\.(_is_owner|_can_[a-z_]+|current_staff_role)' AND p.prosrc !~ 'coalesce\\(public\\.(_is_owner|_can_)'")
q("5 has_permission source", "SELECT left(prosrc, 600) FROM pg_proc WHERE proname = 'has_permission' LIMIT 1")
q("6 biggest tables", "SELECT string_agg(relname || '=' || pg_size_pretty(pg_total_relation_size(c.oid)), ', ' ORDER BY pg_total_relation_size(c.oid) DESC) FROM (SELECT * FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname='public' AND c.relkind='r' ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 12) c")
q("7 database size", "SELECT pg_size_pretty(pg_database_size(current_database()))")
q("8 duplicate contacts (same customer, same phone/email)", "SELECT count(*) FROM (SELECT customer_id, kind, lower(regexp_replace(value, '[^0-9a-zA-Z@.]', '', 'g')) v, count(*) FROM customer_contacts GROUP BY 1,2,3 HAVING count(*) > 1) x")
q("9 customers with no phone and no email", "SELECT count(*) FROM customers c WHERE c.merged_into_id IS NULL AND NOT EXISTS (SELECT 1 FROM customer_contacts k WHERE k.customer_id = c.id)")
q("10 mobile vs phone kinds", "SELECT kind, count(*) FROM customer_contacts GROUP BY 1 ORDER BY 2 DESC")
q("11 monitoring: contracts / security monitoring customers", "SELECT (SELECT count(*) FROM monitoring_contracts), (SELECT count(DISTINCT i.customer_id) FROM invoices i JOIN business_units b ON b.id = i.business_unit_id WHERE b.name ILIKE '%monitor%' AND i.invoice_date > now() - interval '15 months')")
q("12 open estimates older than 30 days not followed up", "SELECT count(*) FROM estimates WHERE status IN ('draft','sent') AND created_at < now() - interval '30 days' AND cancelled_at IS NULL")
q("13 setup files applied (setup_applied) vs newest", "SELECT count(*), max(file), max(applied_at) FROM setup_applied")
q("14 indexes still missing", "SELECT string_agg(i, ', ') FROM unnest(ARRAY['invoices_total_idx','invoices_balance_idx','invoices_paid_idx','invoices_customer_bu_idx','customers_number_idx']) i WHERE to_regclass('public.' || i) IS NULL")
q("15 slowest queries (if pg_stat_statements is on)", "SELECT string_agg(left(regexp_replace(query, '\\s+', ' ', 'g'), 70) || ' = ' || round(mean_exec_time)::text || 'ms x' || calls, ' | ') FROM (SELECT * FROM pg_stat_statements WHERE calls > 20 ORDER BY mean_exec_time * calls DESC LIMIT 8) s")
q("16 staff without a cell on their employee record", "SELECT count(*) FILTER (WHERE coalesce(length(regexp_replace(e.mobile_phone, '\\D', '', 'g')), 0) < 10), count(*) FROM app_users u JOIN employees e ON e.id = u.employee_id WHERE coalesce((to_jsonb(u) ->> 'active')::boolean, true)")
q("17 audit_log size and oldest", "SELECT count(*), min(changed_at) FROM audit_log")
q("18 jobs scheduled today without a tech", "SELECT count(*) FROM visits v WHERE v.scheduled_date = current_date AND v.status NOT IN ('cancelled','completed') AND NOT EXISTS (SELECT 1 FROM visit_technicians vt WHERE vt.visit_id = v.id)")
q("19 invoices owing over 90 days", "SELECT count(*), round(sum(balance_due)) FROM invoices WHERE balance_due > 0.004 AND status NOT IN ('void','draft') AND invoice_date < now() - interval '90 days'")
q("20 memberships expiring in next 60 days", "SELECT count(*) FROM memberships WHERE status = 'active' AND end_date BETWEEN current_date AND current_date + 60")

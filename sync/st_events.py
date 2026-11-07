"""Every hour: copy the events on the techs' ServiceTitan schedules (non-job appointments) and the techs' job timesheets
(arrived / Done) into the app, so Tech Calls, Payroll and the "call not closed" warning show same-day changes.
Only reads ServiceTitan. Uses the same settings (GitHub secrets) as the nightly sync."""
import os, sys
from datetime import datetime, timezone
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import st_sync

st_sync.QUIET = True
st_s, db = st_sync.settings()
conn = st_sync.connect(db)
st = st_sync.ST(st_s)
with conn.cursor() as cur:
    st_sync.sync_nonjob(st, conn, cur, datetime.now(timezone.utc))
with conn.cursor() as cur:   # timesheets: carry on from where the last run (this one or the nightly) stopped
    try:
        cur.execute("SELECT continue_from, since FROM st_sync_state WHERE endpoint = 'job-timesheets'")
        r = cur.fetchone(); state = {"job-timesheets": {"continue_from": r[0], "since": r[1].isoformat() if r[1] else None}} if r else {}
        new_state = {}
        n = st_sync.sync_job_timesheets(cur, st, state, new_state)
        v = new_state.get("job-timesheets")
        if v:
            cur.execute("INSERT INTO st_sync_state (endpoint, continue_from, since, updated_at) VALUES (%s, %s, %s, now()) "
                        "ON CONFLICT (endpoint) DO UPDATE SET continue_from = EXCLUDED.continue_from, since = EXCLUDED.since, updated_at = now()",
                        ("job-timesheets", v["continue_from"], v["since"]))
        conn.commit(); print(f"Job timesheets: {n} brought in", flush=True)
    except Exception as e:
        conn.rollback(); print(f"Job timesheets not brought in this time: {str(e)[:300]}", flush=True)
with conn.cursor() as cur:   # once: ServiceTitan's own tax for invoices saved before it was kept (sync/extra/217), starting with those that have discounts
    try:
        cur.execute("SELECT to_regclass('public.invoices') IS NOT NULL AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'invoices' AND column_name = 'tax_st')")
        if cur.fetchone()[0]:
            cur.execute("""SELECT i.id FROM invoices i WHERE i.tax_st IS NULL AND i.st_id IS NOT NULL AND i.app_edited_at IS NULL AND i.status NOT IN ('void', 'draft')
                           AND EXISTS (SELECT 1 FROM invoice_lines l WHERE l.invoice_id = i.id AND l.line_type = 'discount') ORDER BY i.id DESC LIMIT 2000""")
            ids = [r[0] for r in cur.fetchall()]; fixed = 0
            for k in range(0, len(ids), 50):
                part = ids[k:k + 50]
                o = st.get("accounting/v2/tenant/{t}/invoices", {"ids": ",".join(map(str, part)), "pageSize": 50}) or {}
                for r in o.get("data") or []:
                    tax = r.get("salesTax")
                    if tax is None: continue
                    cur.execute("UPDATE invoices SET tax_st = %s WHERE id = %s", (round(float(tax), 2), int(r["id"])))
                    cur.execute("SELECT public.recalc_invoice(%s)", (int(r["id"]),)); fixed += 1
                conn.commit()
            if ids: print(f"ServiceTitan tax brought in for {fixed} of {len(ids)} invoices with discounts", flush=True)
    except Exception as e:
        conn.rollback(); print(f"ServiceTitan tax not brought in this time: {str(e)[:300]}", flush=True)
conn.close()

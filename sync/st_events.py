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
conn.close()

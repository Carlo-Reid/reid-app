"""Every hour: copy the events on the techs' ServiceTitan schedules (non-job appointments) into the app, so Tech Calls and
Payroll show same-day changes. Only reads ServiceTitan. Uses the same settings (GitHub secrets) as the nightly sync."""
import os, sys
from datetime import datetime, timezone
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import st_sync

st_sync.QUIET = True
st_s, db = st_sync.settings()
conn = st_sync.connect(db)
with conn.cursor() as cur:
    st_sync.sync_nonjob(st_sync.ST(st_s), conn, cur, datetime.now(timezone.utc))
conn.close()

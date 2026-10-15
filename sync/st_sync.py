"""
ServiceTitan -> Supabase sync.

Pulls everything that changed in ServiceTitan since the last run (customers, addresses, phone numbers,
jobs, visits and the techs on them, estimates, invoices and their lines, payments, plans, equipment,
staff, job types) and saves it into the app's database. Notes on the customers, addresses and jobs
that changed are brought over too. ServiceTitan is read only; nothing is ever sent back to it.

Runs:
  * every night on GitHub (see .github/workflows/servicetitan-sync.yml), using the repository's secrets
  * whenever you like on your computer with SYNC NOW.bat (it reads servicetitan-settings.txt and
    supabase-settings.txt from the Sevice Titan Export folder)

The first run picks up from the October export: it reads the "continue from here" marker ServiceTitan
gave at the end of each part of that export (in export_*/raw-json). After that the markers are kept in
the database (table st_sync_state), so the nightly run on GitHub carries on from where the last run stopped.
"""
import argparse, csv, json, os, subprocess, sys, tempfile, time, glob, re
import urllib.parse, urllib.request, urllib.error
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
API = "https://api.servicetitan.io/"
AUTH = "https://auth.servicetitan.io/connect/token"
UA = "ReidFieldService-Sync/1.0"
LOG_LINES = []
# On GitHub the run log can be seen by anyone who opens the repository, so it never shows customer details there:
# the full reason for a failed run is saved in the database and shown on the app's Settings page.
QUIET = bool(os.environ.get("GITHUB_ACTIONS"))


def log(msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    LOG_LINES.append(line)


# ---------------------------------------------------------------------------
# settings: environment variables (GitHub) or the settings files (your computer)
# ---------------------------------------------------------------------------
def read_kv(path):
    s = {}
    for line in open(path, encoding="utf-8-sig"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            s[k.strip().upper()] = v.strip().strip('"').strip("'")
    return s


def find_file(name):
    d = HERE
    for _ in range(4):
        p = os.path.join(d, name)
        if os.path.exists(p): return p
        d = os.path.dirname(d)
    return None


def settings():
    st, db = {}, {}
    if QUIET and not (os.environ.get("ST_CLIENT_ID") and os.environ.get("DB_HOST")):
        sys.exit("The GitHub secrets aren't all set. Add ST_TENANT_ID, ST_APP_KEY, ST_CLIENT_ID, ST_CLIENT_SECRET, "
                 "DB_HOST, DB_PORT, DB_NAME, DB_USER and DB_PASSWORD under Settings > Secrets and variables > Actions.")
    if os.environ.get("ST_CLIENT_ID"):
        st = {k: os.environ.get("ST_" + k, "") for k in ("TENANT_ID", "APP_KEY", "CLIENT_ID", "CLIENT_SECRET")}
    else:
        p = find_file("servicetitan-settings.txt")
        if not p: sys.exit("Can't find servicetitan-settings.txt (put this folder inside the Sevice Titan Export folder).")
        st = read_kv(p)
    if os.environ.get("DB_HOST"):
        db = {k: os.environ.get(k, "") for k in ("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD", "DB_SSLMODE")}
    else:
        p = find_file("supabase-settings.txt")
        if not p: sys.exit("Can't find supabase-settings.txt (put this folder inside the Sevice Titan Export folder).")
        db = read_kv(p)
    miss = [k for k in ("TENANT_ID", "APP_KEY", "CLIENT_ID", "CLIENT_SECRET") if not st.get(k)]
    miss += [k for k in ("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD") if not db.get(k)]
    if miss: sys.exit("These settings are missing: " + ", ".join(miss))
    return st, db


# ---------------------------------------------------------------------------
# ServiceTitan API (read only)
# ---------------------------------------------------------------------------
class ST:
    def __init__(self, s):
        self.s, self.token, self.t0, self.prefix, self.confirmed = s, None, 0, "", False
        self.calls = 0

    def auth(self):
        body = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": self.s["CLIENT_ID"],
                                       "client_secret": self.s["CLIENT_SECRET"]}).encode()
        req = urllib.request.Request(AUTH, data=body, headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": UA})
        with urllib.request.urlopen(req, timeout=60) as r:
            self.token = json.load(r)["access_token"]
        self.t0 = time.time()

    def get(self, path, params=None):
        url = API + path.replace("{t}", self.s["TENANT_ID"])
        if params: url += "?" + urllib.parse.urlencode(params)
        switched = False
        for attempt in range(1, 9):
            if not self.token or time.time() - self.t0 > 12 * 60: self.auth()
            req = urllib.request.Request(url, headers={"Authorization": self.prefix + self.token, "ST-App-Key": self.s["APP_KEY"],
                                                       "Accept": "application/json", "User-Agent": UA})
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    self.confirmed = True; self.calls += 1
                    return json.load(r)
            except urllib.error.HTTPError as e:
                if e.code == 401 and not self.confirmed and not switched:
                    self.prefix = "Bearer " if self.prefix == "" else ""; switched = True; self.auth(); continue
                if e.code == 429 or 500 <= e.code < 600:
                    time.sleep(min(60, 5 * attempt)); continue
                raise RuntimeError(f"ServiceTitan said HTTP {e.code} for {path.split('/tenant/')[0]}: {e.read()[:300]!r}")
            except (urllib.error.URLError, TimeoutError):
                time.sleep(min(60, 5 * attempt))
        raise RuntimeError("ServiceTitan didn't answer after several tries.")


# What to pull. 'export' feeds remember where they stopped (continueFrom); 'full' lists are small and
# re-read every time; 'modified' lists are read by "changed since".
FEEDS = [
    ("customers",               "crm/v2/tenant/{t}/export/customers",                    "export"),
    ("customer-contacts",       "crm/v2/tenant/{t}/export/customers/contacts",           "export"),
    ("locations",               "crm/v2/tenant/{t}/export/locations",                    "export"),
    ("location-contacts",       "crm/v2/tenant/{t}/export/locations/contacts",           "export"),
    ("leads",                   "crm/v2/tenant/{t}/export/leads",                        "export"),
    ("bookings",                "crm/v2/tenant/{t}/export/bookings",                     "export"),
    ("projects",                "jpm/v2/tenant/{t}/export/projects",                     "export"),
    ("jobs",                    "jpm/v2/tenant/{t}/export/jobs",                         "export"),
    ("appointments",            "jpm/v2/tenant/{t}/export/appointments",                 "export"),
    ("appointment-assignments", "dispatch/v2/tenant/{t}/export/appointment-assignments", "export"),
    ("estimates",               "sales/v2/tenant/{t}/estimates/export",                  "export"),
    ("invoices",                "accounting/v2/tenant/{t}/export/invoices",              "export"),
    ("invoice-items",           "accounting/v2/tenant/{t}/export/invoice-items",         "export"),
    ("payments",                "accounting/v2/tenant/{t}/export/payments",              "export"),
    ("memberships",             "memberships/v2/tenant/{t}/export/memberships",          "export"),
    ("membership-types",        "memberships/v2/tenant/{t}/export/membership-types",     "full"),
    ("employees",               "settings/v2/tenant/{t}/export/employees",               "full"),
    ("technicians",             "settings/v2/tenant/{t}/export/technicians",             "full"),
    ("job-types",               "jpm/v2/tenant/{t}/job-types",                           "page"),
    ("business-units",          "settings/v2/tenant/{t}/business-units",                 "page"),
    ("installed-equipment",     "equipmentsystems/v2/tenant/{t}/installed-equipment",    "modified"),
]


def pull_export(st, path, start_from):
    """Everything since the marker. Returns (records, new marker)."""
    recs, frm = {}, start_from
    for _ in range(5000):
        params = {"includeRecentChanges": "true"}
        if frm: params["from"] = frm
        o = st.get(path, params)
        for r in o.get("data") or []:
            recs[r.get("id")] = r            # the same record can come twice: keep the newest
        nxt = o.get("continueFrom")
        if not o.get("hasMore") or not nxt or nxt == frm:
            return list(recs.values()), (nxt or frm)
        frm = nxt
    return list(recs.values()), frm


def pull_pages(st, path, extra=None):
    recs = []
    for page in range(1, 2000):
        o = st.get(path, {"page": page, "pageSize": 500, **(extra or {})})
        recs += o.get("data") or []
        if not o.get("hasMore"): break
    return recs


def cell(v):
    """The same text form the original export used, so the converter reads it the same way."""
    if v is None: return ""
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, (int, float)): return repr(v) if isinstance(v, float) else str(v)
    if isinstance(v, str): return v
    return json.dumps(v, separators=(",", ":"))


def write_csv(path, recs):
    cols = []
    for r in recs:
        for k in r:
            if k not in cols: cols.append(k)
    with open(path, "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh); w.writerow(cols)
        for r in recs: w.writerow([cell(r.get(c)) for c in cols])


# ---------------------------------------------------------------------------
# first run: markers from the October export
# ---------------------------------------------------------------------------
def seed_from_export():
    root = os.path.dirname(find_file("servicetitan-settings.txt") or HERE)
    folders = sorted(glob.glob(os.path.join(root, "export_*")))
    if not folders:
        return None
    exp = folders[-1]
    raw = os.path.join(exp, "raw-json")
    state = {}
    for name, _, kind in FEEDS:
        if kind != "export": continue
        pages = sorted(glob.glob(os.path.join(raw, f"{name}_*.json")))
        if not pages: continue
        last = json.load(open(pages[-1], encoding="utf-8"))
        if last.get("continueFrom"): state[name] = {"continue_from": last["continueFrom"], "since": None}
    m = re.search(r"export_(\d{4}-\d{2}-\d{2})_(\d{2})(\d{2})", os.path.basename(exp))
    since = (datetime.fromisoformat(f"{m.group(1)}T{m.group(2)}:{m.group(3)}:00") - timedelta(days=1)).replace(tzinfo=timezone.utc) if m else None
    state["installed-equipment"] = {"continue_from": None, "since": since.isoformat() if since else None}
    log(f"First run: starting from the export in {os.path.basename(exp)} ({len(state) - 1} markers found).")
    return state


# ---------------------------------------------------------------------------
# database
# ---------------------------------------------------------------------------
def connect(db):
    try:
        import psycopg
    except ImportError:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "psycopg[binary]"]); import psycopg
    return psycopg.connect(host=db["DB_HOST"], port=int(db["DB_PORT"]), dbname=db["DB_NAME"], user=db["DB_USER"],
                           password=db["DB_PASSWORD"], sslmode=db.get("DB_SSLMODE") or "require", connect_timeout=30)


def known_from_db(cur, delta_dir):
    """What's already in the database, so the converter can link new records to old ones."""
    def ids(sql):
        cur.execute(sql); return [r[0] for r in cur.fetchall()]
    k = {}
    k["customer_ids"] = ids("SELECT id FROM customers")
    cur.execute("SELECT id, customer_id FROM locations"); lc = cur.fetchall()
    k["location_ids"] = [r[0] for r in lc]; k["location_customer"] = {r[0]: r[1] for r in lc}
    k["employee_ids"] = ids("SELECT id FROM employees")
    k["project_ids"] = ids("SELECT id FROM projects")
    cur.execute("SELECT id, job_type_id FROM jobs"); jt = cur.fetchall()
    k["job_ids"] = [r[0] for r in jt]; k["job_type_of_job"] = {r[0]: r[1] for r in jt}
    k["visit_ids"] = ids("SELECT id FROM visits")
    k["plan_type_ids"] = ids("SELECT id FROM plan_types")
    k["estimate_ids"] = ids("SELECT id FROM estimates")
    k["invoice_ids"] = ids("SELECT id FROM invoices")
    cur.execute("SELECT id, name, active, default_duration_minutes FROM job_types")
    k["job_types"] = {r[0]: [r[1], r[2], r[3]] for r in cur.fetchall()}
    cur.execute("SELECT id, name FROM manufacturers"); k["manufacturers"] = {r[1].upper(): [r[0], r[1]] for r in cur.fetchall()}
    cur.execute("SELECT id, name FROM equipment_types"); k["equipment_types"] = {r[1].upper(): [r[0], r[1]] for r in cur.fetchall()}
    cur.execute("SELECT id, name FROM suppliers"); k["suppliers"] = {r[1]: r[0] for r in cur.fetchall()}
    cur.execute("SELECT item_type, st_id, id FROM pricebook_items WHERE st_id IS NOT NULL"); k["pricebook"] = cur.fetchall()
    # visits already numbered on jobs that have changed visits
    appt = os.path.join(delta_dir, "appointments.csv")
    job_ids = set()
    if os.path.exists(appt):
        for r in csv.DictReader(open(appt, encoding="utf-8-sig")):
            if r.get("jobId"): job_ids.add(int(float(r["jobId"])))
    k["visit_nums"] = {}
    if job_ids:
        cur.execute("SELECT job_id, id, visit_number FROM visits WHERE job_id = ANY(%s)", (list(job_ids),))
        for jid, vid, n in cur.fetchall(): k["visit_nums"].setdefault(jid, {})[vid] = n
    aa = os.path.join(delta_dir, "appointment-assignments.csv")
    vids = set()
    if os.path.exists(aa):
        for r in csv.DictReader(open(aa, encoding="utf-8-sig")):
            if r.get("appointmentId"): vids.add(int(float(r["appointmentId"])))
    k["visits_with_tech"] = []
    if vids:
        cur.execute("SELECT DISTINCT visit_id FROM visit_assignments WHERE visit_id = ANY(%s)", (list(vids),))
        k["visits_with_tech"] = [r[0] for r in cur.fetchall()]
    # tax rate of invoices whose lines changed
    ii = os.path.join(delta_dir, "invoice-items.csv")
    iids = set()
    if os.path.exists(ii):
        for r in csv.DictReader(open(ii, encoding="utf-8-sig")):
            if r.get("invoiceId"): iids.add(int(float(r["invoiceId"])))
    k["invoice_tax_rate"] = {}
    if iids:
        cur.execute("SELECT id, subtotal, tax_total FROM invoices WHERE id = ANY(%s)", (list(iids),))
        for i, sub, tax in cur.fetchall():
            sub, tax = float(sub or 0), float(tax or 0)
            k["invoice_tax_rate"][i] = round(tax / sub * 100, 2) if sub and tax and 0 < tax / sub < 0.2 else 0
    return k


# How each table is saved: ('id') = add or update by id; ('st_id') = add or update by ServiceTitan id;
# ('new') = only add rows that aren't there yet; special cases handled in save().
SAVE = {
    "employees": "id", "customers": "id", "customer_flags": "flag", "locations": "id", "customer_contacts": "contact",
    "job_types": "new", "projects": "id", "jobs": "id", "visits": "id", "visit_assignments": "st_id",
    "plan_types": "id", "memberships": "id", "equipment": "id", "warranty_coverages": "warranty",
    "estimates": "id", "estimate_options": "id", "estimate_lines": "est_lines", "job_sold_estimates": "sold",
    "invoices": "id", "invoice_lines": "id", "payments": "id", "payment_applications": "pay_apps", "leads": "id",
    "suppliers": "new", "manufacturers": "new", "equipment_types": "new", "partners": "skip",
}
# columns the app owns: never overwritten by ServiceTitan
KEEP = {"equipment": {"no_warranty", "requested_info", "ignored_info"}}


def save(cur, out_dir, manifest):
    counts = {}
    for t in manifest:
        table, cols, n = t["table"], t["columns"], t["rows"]
        how = SAVE.get(table, "skip")
        if not n or how == "skip": continue
        t0 = time.time()
        tmp = f"_s_{table}"
        collist = ", ".join(cols)
        cur.execute(f"CREATE TEMP TABLE {tmp} ON COMMIT DROP AS SELECT {collist} FROM {table} WITH NO DATA" if table != "job_sold_estimates"
                    else f"CREATE TEMP TABLE {tmp} (job_id bigint, estimate_id bigint) ON COMMIT DROP")
        with open(os.path.join(out_dir, t["file"]), "rb") as fh:
            fh.readline()
            with cur.copy(f"COPY {tmp} ({collist}) FROM STDIN (FORMAT csv, NULL '\\N')") as cp:
                while True:
                    chunk = fh.read(1 << 20)
                    if not chunk: break
                    cp.write(chunk)
        upd = ", ".join(f"{c} = EXCLUDED.{c}" for c in cols if c not in ("id", "created_at") and c not in KEEP.get(table, ()))
        sel = ", ".join(cols)
        if how == "id":
            cur.execute(f"INSERT INTO {table} ({collist}) OVERRIDING SYSTEM VALUE SELECT {sel} FROM {tmp} "
                        f"ON CONFLICT (id) DO UPDATE SET {upd}")
        elif how == "st_id":
            cur.execute(f"INSERT INTO {table} ({collist}) SELECT {sel} FROM {tmp} ON CONFLICT (st_id) DO UPDATE SET {upd}")
        elif how == "new":
            cur.execute(f"INSERT INTO {table} ({collist}) OVERRIDING SYSTEM VALUE SELECT {sel} FROM {tmp} ON CONFLICT DO NOTHING")
        elif how == "flag":
            cur.execute(f"INSERT INTO {table} ({collist}) SELECT {sel} FROM {tmp} s WHERE NOT EXISTS "
                        f"(SELECT 1 FROM {table} f WHERE f.customer_id = s.customer_id AND f.flag_type = s.flag_type AND f.resolved_at IS NULL)")
        elif how == "contact":
            setc = ", ".join(f"{c} = s.{c}" for c in cols if c != "st_id")
            cur.execute(f"UPDATE {table} c SET {setc} FROM {tmp} s WHERE c.st_id = s.st_id")
            cur.execute(f"INSERT INTO {table} ({collist}) SELECT {sel} FROM {tmp} s WHERE NOT EXISTS (SELECT 1 FROM {table} c WHERE c.st_id = s.st_id)")
        elif how == "warranty":
            cur.execute(f"INSERT INTO {table} ({collist}) SELECT {sel} FROM {tmp} s WHERE NOT EXISTS (SELECT 1 FROM {table} w "
                        f"WHERE w.equipment_id = s.equipment_id AND w.source = s.source AND w.start_date = s.start_date AND w.end_date = s.end_date)")
        elif how == "est_lines":
            cur.execute(f"DELETE FROM {table} WHERE estimate_option_id IN (SELECT DISTINCT estimate_option_id FROM {tmp})")
            cur.execute(f"INSERT INTO {table} ({collist}) SELECT {sel} FROM {tmp}")
        elif how == "pay_apps":
            cur.execute(f"DELETE FROM {table} WHERE payment_id IN (SELECT DISTINCT payment_id FROM {tmp})")
            cur.execute(f"INSERT INTO {table} ({collist}) SELECT {sel} FROM {tmp}")
        elif how == "sold":
            cur.execute(f"UPDATE jobs j SET sold_estimate_id = s.estimate_id FROM {tmp} s WHERE s.job_id = j.id")
        counts[table] = n
        if time.time() - t0 > 5: log(f"  {table}: {n} rows in {time.time() - t0:.0f}s")
    return counts


def remove_gone(cur, delta):
    """Phone numbers, techs and invoice lines that were removed in ServiceTitan."""
    gone = {}
    def ids_of(name, test):
        return [int(r["id"]) for r in delta.get(name, []) if test(r)]
    c = ids_of("customer-contacts", lambda r: r.get("active") is False) + ids_of("location-contacts", lambda r: r.get("active") is False)
    if c:
        cur.execute("DELETE FROM customer_contacts WHERE st_id = ANY(%s)", (c,)); gone["phone numbers / emails"] = cur.rowcount
    a = ids_of("appointment-assignments", lambda r: r.get("active") is False)
    if a:
        cur.execute("DELETE FROM visit_assignments WHERE st_id = ANY(%s)", (a,)); gone["techs taken off calls"] = cur.rowcount
    il = ids_of("invoice-items", lambda r: r.get("active") is False)
    if il:
        cur.execute("DELETE FROM invoice_lines WHERE id = ANY(%s)", (il,)); gone["invoice lines"] = cur.rowcount
    return gone


def sync_notes(cur, st, delta):
    """Notes on the customers, addresses and jobs that changed."""
    targets = []
    for kind, feed, path in (("customer", "customers", "crm/v2/tenant/{t}/customers/{id}/notes"),
                             ("location", "locations", "crm/v2/tenant/{t}/locations/{id}/notes"),
                             ("job", "jobs", "jpm/v2/tenant/{t}/jobs/{id}/notes")):
        for r in delta.get(feed, []):
            targets.append((kind, int(r["id"]), path.replace("{id}", str(r["id"]))))
    if not targets: return 0
    table = {"customer": "customers", "location": "locations", "job": "jobs"}
    rows = []
    for kind, eid, path in targets[:3000]:
        try:
            for n in pull_pages(st, path):
                text = (n.get("text") or "").strip()
                if text: rows.append((kind, eid, text, bool(n.get("isPinned")), n.get("createdOn") or n.get("modifiedOn"), n.get("createdById") or None))
        except RuntimeError as e:
            log(f"  couldn't read notes for {kind} {eid}: {e}")
    if not rows: return 0
    cur.execute("DROP TABLE IF EXISTS _s_notes")
    cur.execute("CREATE TEMP TABLE _s_notes (entity_type text, entity_id bigint, body text, pinned boolean, created text, created_by bigint) ON COMMIT DROP")
    with cur.copy("COPY _s_notes FROM STDIN") as cp:
        for r in rows: cp.write_row(r)
    has_author = True
    cur.execute("SELECT 1 FROM information_schema.columns WHERE table_name = 'notes' AND column_name = 'author_name'")
    has_author = bool(cur.fetchone())
    author_cols = ", st_created_by, author_name" if has_author else ""
    author_vals = (", n.created_by, (SELECT nullif(btrim(regexp_replace(coalesce(e.first_name, '') || ' ' || coalesce(e.last_name, ''), '^ZPast-', '')), '') "
                   "|| CASE WHEN e.first_name LIKE 'ZPast-%' THEN ' (former staff)' ELSE '' END FROM employees e WHERE e.st_id = n.created_by)") if has_author else ""
    cur.execute(f"""
        INSERT INTO notes (entity_type, entity_id, body, pinned, st_id, source, created_at{author_cols})
        SELECT DISTINCT ON (n.entity_type, n.entity_id, n.body, n.created)
               n.entity_type, n.entity_id, n.body, n.pinned, -1, 'st_sync', coalesce(nullif(n.created, '')::timestamptz, now()){author_vals}
        FROM _s_notes n
        WHERE (n.entity_type <> 'customer' OR EXISTS (SELECT 1 FROM customers c WHERE c.id = n.entity_id))
          AND (n.entity_type <> 'location' OR EXISTS (SELECT 1 FROM locations l WHERE l.id = n.entity_id))
          AND (n.entity_type <> 'job' OR EXISTS (SELECT 1 FROM jobs j WHERE j.id = n.entity_id))
          AND NOT EXISTS (SELECT 1 FROM notes x WHERE x.entity_type = n.entity_type AND x.entity_id = n.entity_id
                          AND x.body = n.body AND x.created_at = coalesce(nullif(n.created, '')::timestamptz, x.created_at))""")
    return cur.rowcount


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default="manual")
    ap.add_argument("--from-files", help="(testing) read the changes from a folder of saved ServiceTitan pages instead of the API")
    args = ap.parse_args()
    started = datetime.now(timezone.utc)
    st_s, db_s = settings() if not args.from_files else ({}, settings_db_only())
    try:
        conn = connect(db_s)
    except Exception as e:
        sys.exit("Couldn't connect to the database." + ("" if QUIET else f" ({e})") +
                 " Check DB_HOST, DB_PORT, DB_USER and DB_PASSWORD (on GitHub use the Session pooler details from Supabase).")
    cur = conn.cursor()
    cur.execute("SET statement_timeout = 0")
    cur.execute("SELECT to_regclass('public.st_sync_state') IS NOT NULL")
    if not cur.fetchone()[0]:
        sys.exit("Run app\\setup\\RUN SETUP.bat first (it adds setup file 24), then run this again.")
    # only one sync at a time
    cur.execute("SELECT pg_try_advisory_lock(80451)")
    if not cur.fetchone()[0]:
        sys.exit("Another sync is running right now. Try again in a few minutes.")
    cur.execute("INSERT INTO st_sync_runs (source) VALUES (%s) RETURNING id", (args.source,))
    run_id = cur.fetchone()[0]; conn.commit()

    try:
        cur.execute("SELECT endpoint, continue_from, since FROM st_sync_state")
        state = {e: {"continue_from": c, "since": s.isoformat() if s else None} for e, c, s in cur.fetchall()}
        if not state and not args.from_files:
            state = seed_from_export()
            if not state:
                raise RuntimeError("This is the first sync and there's no ServiceTitan export folder to start from. "
                                   "Run SYNC NOW.bat once on the computer that has the export_... folder.")
        st = ST(st_s) if not args.from_files else None
        delta, new_state = {}, {}
        log("Asking ServiceTitan what changed...")
        for name, path, kind in FEEDS:
            if args.from_files:
                pages = sorted(glob.glob(os.path.join(args.from_files, f"{name}_*.json")))
                recs = [r for p in pages for r in json.load(open(p, encoding="utf-8")).get("data") or []]
                delta[name] = recs; continue
            if kind == "export":
                prev = (state.get(name) or {}).get("continue_from")
                if not prev:
                    log(f"  {name:<24} no starting point yet, skipped (it starts next time)")
                    _, marker = pull_export_marker_only(st, path)
                    new_state[name] = {"continue_from": marker, "since": None}; continue
                recs, marker = pull_export(st, path, prev)
                new_state[name] = {"continue_from": marker, "since": None}
            elif kind == "full":
                recs, _ = pull_export(st, path, None)
            elif kind == "page":
                recs = pull_pages(st, path)
            else:   # modified since
                since = (state.get(name) or {}).get("since") or (started - timedelta(days=2)).isoformat()
                recs = pull_pages(st, path, {"modifiedOnOrAfter": since})
                new_state[name] = {"continue_from": None, "since": (started - timedelta(hours=1)).isoformat()}
            delta[name] = recs
            if kind in ("export", "modified"): log(f"  {name:<24} {len(recs):>6} changed")

        work = tempfile.mkdtemp(prefix="st_sync_")
        src, out = os.path.join(work, "changes"), os.path.join(work, "load")
        os.makedirs(src); os.makedirs(out)
        for name, recs in delta.items():
            if recs: write_csv(os.path.join(src, name + ".csv"), recs)
        k = known_from_db(cur, src)
        kpath = os.path.join(work, "known.json")
        json.dump(k, open(kpath, "w", encoding="utf-8"), default=str)
        log("Converting...")
        r = subprocess.run([sys.executable, os.path.join(HERE, "convert.py"), src, out],
                           env={**os.environ, "ST_DELTA_KNOWN": kpath}, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError("The converter stopped: " + (r.stderr or r.stdout)[-1500:])
        manifest = json.load(open(os.path.join(out, "manifest.json"), encoding="utf-8"))["tables"]
        report = json.load(open(os.path.join(out, "report.json"), encoding="utf-8"))

        log("Saving to the database...")
        cur.execute("ALTER TABLE invoice_lines DISABLE TRIGGER USER; ALTER TABLE payment_applications DISABLE TRIGGER USER")
        cur.execute("SET CONSTRAINTS ALL DEFERRED")
        counts = save(cur, out, manifest)
        gone = remove_gone(cur, delta)
        cur.execute("ALTER TABLE invoice_lines ENABLE TRIGGER USER; ALTER TABLE payment_applications ENABLE TRIGGER USER")
        notes = sync_notes(cur, st, delta) if st else 0
        for name, v in new_state.items():
            cur.execute("INSERT INTO st_sync_state (endpoint, continue_from, since, updated_at) VALUES (%s, %s, %s, now()) "
                        "ON CONFLICT (endpoint) DO UPDATE SET continue_from = EXCLUDED.continue_from, since = EXCLUDED.since, updated_at = now()",
                        (name, v["continue_from"], v["since"]))
        summary = {"changed": {n: len(r) for n, r in delta.items() if r and n not in ("employees", "technicians", "job-types", "business-units", "membership-types")},
                   "saved": counts, "removed": gone, "notes_added": notes, "skipped": report.get("skipped", {}),
                   "api_calls": st.calls if st else 0}
        cur.execute("UPDATE st_sync_runs SET finished_at = now(), ok = true, summary = %s WHERE id = %s", (json.dumps(summary), run_id))
        conn.commit()
        log("Saved. Updating search...")
        cur.execute("SELECT public._sync_after()")
        conn.commit()
        log("Done: " + ", ".join(f"{v} {k.replace('-', ' ')}" for k, v in summary["changed"].items()) + (f", {notes} notes" if notes else ""))
    except Exception as e:
        conn.rollback()
        try:
            cur.execute("ALTER TABLE invoice_lines ENABLE TRIGGER USER; ALTER TABLE payment_applications ENABLE TRIGGER USER")
        except Exception: conn.rollback()
        cur.execute("UPDATE st_sync_runs SET finished_at = now(), ok = false, error = %s WHERE id = %s", (str(e)[:2000], run_id))
        conn.commit()
        log("Stopped. The reason is on the app's Settings page, under ServiceTitan sync." if QUIET else f"Stopped: {e}")
        sys.exit(1)
    finally:
        try: cur.execute("SELECT pg_advisory_unlock(80451)"); conn.commit()
        except Exception: pass


def pull_export_marker_only(st, path):
    """No marker yet for this feed: read through to the end once, just to get a starting point."""
    return pull_export(st, path, None)


def settings_db_only():
    if os.environ.get("DB_HOST"):
        return {k: os.environ.get(k, "") for k in ("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD", "DB_SSLMODE")}
    return read_kv(find_file("supabase-settings.txt"))


if __name__ == "__main__":
    main()

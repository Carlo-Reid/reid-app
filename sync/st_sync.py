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


def fail(msg):
    """Stop with a message. On GitHub it also shows as a red note on the run (never with customer details)."""
    if QUIET: print("::error::" + msg.replace("\n", " "), flush=True)
    sys.exit(msg)


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
    if QUIET:
        need = ["ST_TENANT_ID", "ST_APP_KEY", "ST_CLIENT_ID", "ST_CLIENT_SECRET", "DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"]
        miss = [k for k in need if not os.environ.get(k, "").strip()]
        if miss:
            fail("These GitHub secrets are missing or empty: " + ", ".join(miss) + ". Check the names under Settings > Secrets and variables > Actions "
                 "(they must be Repository secrets, spelled exactly like this).")
    if os.environ.get("ST_CLIENT_ID"):
        # forgive copy-and-paste extras: spaces, quotes, or the "CLIENT_ID=" label itself
        clean = lambda k, v: re.sub(r"^\s*(ST_)?" + k + r"\s*=\s*", "", v.strip(), flags=re.I).strip().strip('"').strip("'").strip()
        st = {k: clean(k, os.environ.get("ST_" + k, "")) for k in ("TENANT_ID", "APP_KEY", "CLIENT_ID", "CLIENT_SECRET")}
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
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                self.token = json.load(r)["access_token"]
        except urllib.error.HTTPError as e:
            body = e.read()[:200].decode("utf-8", "replace")
            raise RuntimeError(f"ServiceTitan refused the sign-in (HTTP {e.code} {body}). "
                               "Check CLIENT_ID and CLIENT_SECRET: only the part after the = sign, with no spaces.")
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
def latest_export():
    """The newest export_YYYY-MM-DD_HHMM folder (not files like export_notes.py)."""
    root = os.path.dirname(find_file("servicetitan-settings.txt") or HERE)
    found = [p for p in glob.glob(os.path.join(root, "export_*"))
             if os.path.isdir(p) and re.match(r"export_\d{4}-\d{2}-\d{2}_\d{4}$", os.path.basename(p))
             and os.path.isdir(os.path.join(p, "raw-json"))]
    return sorted(found)[-1] if found else None


def seed_from_export():
    exp = latest_export()
    if not exp:
        return None
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
    cur.execute("SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'customers' AND column_name = 'merged_into_id')")
    merged = cur.fetchone()[0]
    if merged:
        cur.execute("SELECT EXISTS (SELECT 1 FROM customers WHERE merged_into_id IS NOT NULL)"); merged = cur.fetchone()[0]
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
        if "customer_id" in cols and merged:   # customers merged in the app: what ServiceTitan files under the old one goes to the one kept
            cur.execute(f"UPDATE {tmp} t SET customer_id = c.merged_into_id FROM customers c WHERE t.customer_id = c.id AND c.merged_into_id IS NOT NULL")
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


def match_assignments(cur, st, day_from, day_to):
    """Make the techs on ServiceTitan's calls in a date range match ServiceTitan exactly.
    (Catches techs moved from one call to another that the change feed didn't report.)"""
    cur.execute("SELECT id FROM visits WHERE scheduled_date BETWEEN %s AND %s AND id < 10000000000 AND status <> 'cancelled'", (day_from, day_to))
    vids = [r[0] for r in cur.fetchall()]
    if not vids: return 0, 0
    want, asked = {}, set()
    for i in range(0, len(vids), 50):
        chunk = vids[i:i + 50]
        try:
            rows = []
            for page in range(1, 20):
                o = st.get("dispatch/v2/tenant/{t}/appointment-assignments",
                           {"appointmentIds": ",".join(map(str, chunk)), "active": "True", "page": page, "pageSize": 500})
                rows += o.get("data") or []
                if not o.get("hasMore"): break
        except RuntimeError as e:
            log(f"  couldn't check the techs on calls ({str(e)[:120]}); left them as they are")
            return None
        stray = [r for r in rows if int(r.get("appointmentId") or 0) not in chunk]
        if stray and len(stray) > len(rows) // 2:
            log("  ServiceTitan didn't filter the call list as expected; left the techs as they are")
            return None
        asked.update(chunk)
        for r in rows:
            vid = int(r.get("appointmentId") or 0)
            if vid in chunk and r.get("active") is not False:
                want.setdefault(vid, []).append((r.get("assignedOn") or "", int(r["technicianId"]), int(r["id"])))
    cur.execute("SELECT visit_id, employee_id FROM visit_assignments WHERE visit_id = ANY(%s)", (list(asked),))
    have = {}
    for v, e in cur.fetchall(): have.setdefault(v, set()).add(e)
    cur.execute("SELECT id FROM employees WHERE id = ANY(%s)", (list({t for l in want.values() for _, t, _ in l}) or [0],))
    known = {r[0] for r in cur.fetchall()}
    removed = added = 0
    for vid in asked:
        techs = [(a, t, sid) for a, t, sid in sorted(want.get(vid, [])) if t in known]
        want_ids = {t for _, t, _ in techs}
        if want_ids == have.get(vid, set()): continue
        cur.execute("DELETE FROM visit_assignments WHERE visit_id = %s AND NOT (employee_id = ANY(%s))", (vid, list(want_ids) or [0]))
        removed += cur.rowcount
        for n, (_, t, sid) in enumerate(techs):
            cur.execute("""INSERT INTO visit_assignments (visit_id, employee_id, role, st_id) VALUES (%s, %s, %s, %s)
                           ON CONFLICT (visit_id, employee_id) DO UPDATE SET role = EXCLUDED.role""",
                        (vid, t, "lead" if n == 0 else "helper", sid))
            added += 1 if t not in have.get(vid, set()) else 0
    return added, removed


PO_STATUS = {"pending": "draft", "sent": "sent", "partiallyreceived": "partially_received", "received": "received",
             "exported": "billed", "canceled": "cancelled", "cancelled": "cancelled"}


def sync_purchase_orders(cur, st, state, new_state):
    """ServiceTitan's purchase orders (and the suppliers on them). All of them the first time, then what changed.
    Saved in bulk, so thousands of POs take seconds, not an hour."""
    try:
        vendors = pull_pages(st, "inventory/v2/tenant/{t}/vendors")
    except RuntimeError as e:
        if "HTTP 403" in str(e) or "HTTP 401" in str(e):
            log("  Purchase orders skipped: the ServiceTitan app key isn't allowed to read Inventory yet "
                "(turn on Inventory read access for the app in ServiceTitan's API settings).")
            return None
        raise
    # ServiceTitan can have two POs with the same number: only the app's own numbers must be unique
    cur.execute("ALTER TABLE purchase_orders DROP CONSTRAINT IF EXISTS purchase_orders_po_number_key")
    cur.execute("DROP INDEX IF EXISTS purchase_orders_po_number_key")
    cur.execute("CREATE UNIQUE INDEX IF NOT EXISTS purchase_orders_app_po_number_key ON purchase_orders (po_number) WHERE st_id IS NULL")
    cur.execute("CREATE UNIQUE INDEX IF NOT EXISTS purchase_orders_st_id_key ON purchase_orders (st_id) WHERE st_id IS NOT NULL")
    prev = (state.get("purchase-orders") or {}).get("continue_from")
    pos, marker = pull_export(st, "inventory/v2/tenant/{t}/export/purchase-orders", prev)
    new_state["purchase-orders"] = {"continue_from": marker, "since": None}
    # one time: the export feed only gave this year's POs, so ask the regular PO list for the older ones, a year at a time
    if not (state.get("po-backfill") or {}).get("since"):
        older, ok = {}, True
        for y in range(2004, datetime.now(timezone.utc).year + 1):
            try:
                got = pull_pages(st, "inventory/v2/tenant/{t}/purchase-orders",
                                 {"createdOnOrAfter": f"{y}-01-01T00:00:00Z", "createdBefore": f"{y + 1}-01-01T00:00:00Z"})
            except RuntimeError as e:
                log(f"  Older purchase orders: ServiceTitan wouldn't list {y} ({str(e)[:160]}); will try again next time.")
                ok = False; break
            for r in got: older[r.get("id")] = r
            if got: log(f"  Older purchase orders: {len(got)} from {y}")
        have = {r.get("id") for r in pos}
        pos = pos + [r for i, r in older.items() if i not in have]
        if ok:
            new_state["po-backfill"] = {"continue_from": None, "since": datetime.now(timezone.utc).isoformat()}
            log(f"  Older purchase orders: {len(older)} found in ServiceTitan's list ({len([i for i in older if i not in have])} not seen before).")
    # suppliers: match by ServiceTitan number, then by name; add the new ones
    cur.execute("DROP TABLE IF EXISTS _s_vend; CREATE TEMP TABLE _s_vend (st_id bigint, name text, active boolean) ON COMMIT DROP")
    with cur.copy("COPY _s_vend FROM STDIN") as cp:
        for v in vendors:
            if (v.get("name") or "").strip(): cp.write_row((int(v["id"]), v["name"].strip(), v.get("active") is not False))
    cur.execute("""UPDATE suppliers s SET st_id = v.st_id FROM _s_vend v
                   WHERE s.st_id IS NULL AND lower(btrim(s.name)) = lower(v.name)
                     AND NOT EXISTS (SELECT 1 FROM suppliers x WHERE x.st_id = v.st_id)""")
    cur.execute("""INSERT INTO suppliers (name, active, st_id) SELECT v.name, v.active, v.st_id FROM _s_vend v
                   WHERE NOT EXISTS (SELECT 1 FROM suppliers x WHERE x.st_id = v.st_id)""")
    if not pos: return 0
    cur.execute("""INSERT INTO suppliers (name, active) SELECT 'Unknown supplier', false
                   WHERE NOT EXISTS (SELECT 1 FROM suppliers WHERE name = 'Unknown supplier')""")
    cur.execute("""DROP TABLE IF EXISTS _s_po; CREATE TEMP TABLE _s_po (st_id bigint, num text, vendor bigint, job bigint, status text, tech bigint,
                   ordered text, expected text, ref text, summary text, total numeric, created text) ON COMMIT DROP""")
    cur.execute("""DROP TABLE IF EXISTS _s_pol; CREATE TEMP TABLE _s_pol (po_st bigint, n int, descr text, qty numeric, cost numeric, rec numeric) ON COMMIT DROP""")
    with cur.copy("COPY _s_po FROM STDIN") as cp:
        for p in pos:
            cp.write_row((int(p["id"]), str(p.get("number") or p["id"]).strip(), int(p.get("vendorId") or 0) or None,
                          int(p.get("jobId") or 0) or None, PO_STATUS.get(str(p.get("status") or "").replace(" ", "").lower(), "sent"),
                          int(p.get("technicianId") or 0) or None, p.get("sentOn") or p.get("date") or p.get("createdOn"),
                          (p.get("requiredOn") or "")[:10] or None, p.get("vendorDocumentNumber") or None,
                          p.get("summary") or None, p.get("total"), p.get("createdOn") or p.get("date")))
    with cur.copy("COPY _s_pol FROM STDIN") as cp:
        for p in pos:
            for n, it in enumerate(p.get("items") or []):
                q = float(it.get("quantity") or 0)
                if q > 0:
                    cp.write_row((int(p["id"]), n, (it.get("description") or it.get("skuName") or it.get("skuCode") or "Item").strip()[:2000],
                                  round(q, 2), round(float(it.get("cost") or 0), 2), round(float(it.get("quantityReceived") or 0), 2)))
    cur.execute("""
        INSERT INTO purchase_orders (po_number, supplier_id, purpose, job_id, status, ordered_by_employee_id, ordered_at, expected_on,
                                     supplier_reference, notes, description, amount, st_id, created_at)
        SELECT CASE WHEN EXISTS (SELECT 1 FROM purchase_orders x WHERE x.po_number = p.num AND x.st_id IS NULL)
                    THEN p.num || ' (ST)' ELSE p.num END,
               coalesce((SELECT id FROM suppliers WHERE st_id = p.vendor LIMIT 1), (SELECT id FROM suppliers WHERE name = 'Unknown supplier' LIMIT 1)),
               CASE WHEN j.id IS NULL THEN 'other' ELSE 'job' END, j.id, p.status, e.id,
               nullif(p.ordered, '')::timestamptz, nullif(p.expected, '')::date, p.ref, p.summary, p.summary, p.total, p.st_id,
               coalesce(nullif(p.created, '')::timestamptz, now())
        FROM (SELECT DISTINCT ON (st_id) * FROM _s_po ORDER BY st_id) p
        LEFT JOIN jobs j ON j.id = p.job LEFT JOIN employees e ON e.id = p.tech
        ON CONFLICT (st_id) WHERE st_id IS NOT NULL DO UPDATE SET supplier_id = EXCLUDED.supplier_id, purpose = EXCLUDED.purpose,
          job_id = EXCLUDED.job_id, status = EXCLUDED.status, ordered_by_employee_id = EXCLUDED.ordered_by_employee_id,
          ordered_at = EXCLUDED.ordered_at, expected_on = EXCLUDED.expected_on, supplier_reference = EXCLUDED.supplier_reference,
          notes = EXCLUDED.notes, description = EXCLUDED.description, amount = EXCLUDED.amount""")
    saved = cur.rowcount
    cur.execute("""DELETE FROM purchase_order_lines l USING purchase_orders po
                   WHERE l.purchase_order_id = po.id AND po.st_id IN (SELECT st_id FROM _s_po)
                     AND NOT EXISTS (SELECT 1 FROM po_receipt_lines r WHERE r.purchase_order_line_id = l.id)""")
    cur.execute("""INSERT INTO purchase_order_lines (purchase_order_id, description, quantity, unit_cost, quantity_received, job_id)
                   SELECT po.id, l.descr, l.qty, l.cost, l.rec, po.job_id FROM _s_pol l JOIN purchase_orders po ON po.st_id = l.po_st
                   ORDER BY po.id, l.n""")
    return saved


OLD_PLACE = re.compile(r"z+ ?-?past|do not use", re.I)

def sync_inventory(cur, st, state, new_state):
    """ServiceTitan's warehouses and trucks (with their techs), which price book items are stocked, and the stock history
    (receipts, transfers, adjustments, returns) kept as read-only history. ServiceTitan has no 'on hand now' list:
    the counts come from its on-hand report, imported on the Stock page. Returns a short summary."""
    out = []
    # warehouses and trucks: one place each, matched by ServiceTitan number (or an unnumbered place with the same name)
    whs = pull_pages(st, "inventory/v2/tenant/{t}/warehouses")
    trucks = pull_pages(st, "inventory/v2/tenant/{t}/trucks")
    def place(rec, kind, parent=None, emp=None):
        nm = (rec.get("name") or "").strip() or f"{kind.title()} {rec['id']}"
        cur.execute("SELECT id FROM stock_locations WHERE st_id = %s", (int(rec["id"]),))
        row = cur.fetchone()
        if not row:
            cur.execute("SELECT id FROM stock_locations WHERE st_id IS NULL AND location_type = %s AND lower(btrim(name)) = lower(%s) LIMIT 1", (kind, nm))
            row = cur.fetchone()
            if row: cur.execute("UPDATE stock_locations SET st_id = %s WHERE id = %s", (int(rec["id"]), row[0]))
        addr = rec.get("address") or {}
        note = ", ".join(x for x in [addr.get("street"), addr.get("city")] if x) or None
        if row:
            # ServiceTitan turning a place off turns it off here; it never turns one back on (places hidden here stay hidden)
            cur.execute("""UPDATE stock_locations SET name = %s, active = CASE WHEN %s THEN active ELSE false END, parent_location_id = coalesce(%s, parent_location_id),
                           assigned_employee_id = coalesce(%s, assigned_employee_id), note = coalesce(note, %s) WHERE id = %s""",
                        (nm, rec.get("active") is not False, parent, emp, note, row[0]))
            return row[0]
        cur.execute("""INSERT INTO stock_locations (name, location_type, active, parent_location_id, assigned_employee_id, st_id, note)
                       VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id""", (nm, kind, rec.get("active") is not False and not OLD_PLACE.search(nm), parent, emp, int(rec["id"]), note))
        return cur.fetchone()[0]
    wmap = {int(w["id"]): place(w, "warehouse") for w in whs}
    for t in trucks:
        emp = None
        for tid in t.get("technicianIds") or []:
            cur.execute("SELECT id FROM employees WHERE st_id = %s", (int(tid),)); r = cur.fetchone()
            if r: emp = r[0]; break
        place(t, "truck", wmap.get(int(t.get("warehouseId") or 0)), emp)
    # once: hide ServiceTitan's old places (ZPast-, ZzPast-, "Do Not Use"); they can be turned back on from the Places tab
    if not state.get("inv-hide-old"):
        cur.execute(r"""UPDATE stock_locations SET active = false WHERE st_id IS NOT NULL AND active
                        AND (name ~* 'z+ ?-?past' OR name ~* 'do not use')""")
        out.append(f"{cur.rowcount} old places hidden")
        new_state["inv-hide-old"] = {"continue_from": None, "since": datetime.now(timezone.utc).isoformat()}
    out.append(f"{len(whs)} warehouses, {len(trucks)} trucks")
    # which price book items are stocked (only ever turns it on: nothing the office set is undone)
    if not (state.get("inv-items") or {}).get("since") or datetime.now(timezone.utc).weekday() == 6:
        stocked = []
        for path in ("pricebook/v2/tenant/{t}/materials", "pricebook/v2/tenant/{t}/equipment"):
            stocked += [int(m["id"]) for m in pull_pages(st, path) if m.get("isInventory")]
        cur.execute("UPDATE pricebook_items SET track_inventory = true WHERE st_id = ANY(%s) AND track_inventory IS NOT TRUE", (stocked,))
        out.append(f"{len(stocked)} items stocked in ServiceTitan ({cur.rowcount} newly marked)")
        new_state["inv-items"] = {"continue_from": None, "since": datetime.now(timezone.utc).isoformat()}
    # supplier part numbers from ServiceTitan's price book (primary and other vendors): the first time, then on Sundays.
    # Fills in what's missing only; a part number or price the office typed is never changed.
    if not (state.get("st-vendor-parts") or {}).get("since") or datetime.now(timezone.utc).weekday() == 6:
        cur.execute("DROP TABLE IF EXISTS _s_vp; CREATE TEMP TABLE _s_vp (item_st bigint, vendor_st bigint, part text, cost numeric, prim boolean) ON COMMIT DROP")
        n = 0
        with cur.copy("COPY _s_vp FROM STDIN") as cp:
            for path in ("pricebook/v2/tenant/{t}/materials", "pricebook/v2/tenant/{t}/equipment"):
                for m in pull_pages(st, path):
                    vs = ([dict(m["primaryVendor"], _p=True)] if m.get("primaryVendor") else []) + [dict(v, _p=False) for v in (m.get("otherVendors") or [])]
                    for v in vs:
                        part = str(v.get("vendorPart") or "").strip()
                        vid = v.get("vendorId")
                        if not vid or v.get("active") is False: continue
                        cost = v.get("cost")
                        cp.write_row((int(m["id"]), int(vid), part[:80] or None, cost if isinstance(cost, (int, float)) and cost > 0 else None, v["_p"])); n += 1
        cur.execute("""INSERT INTO supplier_items (supplier_id, item_id, supplier_sku, cost, is_preferred)
                       SELECT DISTINCT ON (s.id, i.id) s.id, i.id, v.part, v.cost,
                              v.prim AND NOT EXISTS (SELECT 1 FROM supplier_items x WHERE x.item_id = i.id AND x.is_preferred)
                       FROM _s_vp v JOIN pricebook_items i ON i.st_id = v.item_st JOIN suppliers s ON s.st_id = v.vendor_st
                       ORDER BY s.id, i.id, v.prim DESC
                       ON CONFLICT (supplier_id, item_id) DO UPDATE
                         SET supplier_sku = coalesce(supplier_items.supplier_sku, EXCLUDED.supplier_sku),
                             cost = coalesce(supplier_items.cost, EXCLUDED.cost)""")
        out.append(f"supplier part numbers: {n} from ServiceTitan, {cur.rowcount} added or filled in")
        new_state["st-vendor-parts"] = {"continue_from": None, "since": datetime.now(timezone.utc).isoformat()}
    # stock history, read-only: everything the first time, then what changed
    cur.execute("""CREATE TABLE IF NOT EXISTS st_stock_history (
        kind text NOT NULL, line_st_id bigint NOT NULL, doc_st_id bigint, doc_number text, sku_st_id bigint, item_name text, item_code text,
        quantity numeric, unit_cost numeric, from_st bigint, to_st bigint, job_st_id bigint, happened_at timestamptz, memo text, active boolean,
        PRIMARY KEY (kind, line_st_id))""")
    cur.execute("CREATE INDEX IF NOT EXISTS st_stock_history_sku_idx ON st_stock_history (sku_st_id, happened_at DESC)")
    cur.execute("CREATE INDEX IF NOT EXISTS st_stock_history_when_idx ON st_stock_history (happened_at DESC)")
    cur.execute("ALTER TABLE st_stock_history ENABLE ROW LEVEL SECURITY")
    feeds = {"receipts": ("receivedOn", None, "inventoryLocationId"), "returns": ("returnedOn", "inventoryLocationId", None),
             "transfers": ("receivedDate", "fromLocationId", "toLocationId"), "adjustments": ("date", "inventoryLocationId", "inventoryLocationId")}
    started = datetime.now(timezone.utc)
    for kind, (when, frm, to) in feeds.items():
        since = (state.get("inv-" + kind) or {}).get("since")
        recs = pull_pages(st, "inventory/v2/tenant/{t}/" + kind, {"modifiedOnOrAfter": since} if since else None)
        rows = []
        for d in recs:
            at = d.get(when) or d.get("date") or d.get("returnDate") or d.get("createdOn")
            for it in d.get("items") or []:
                q = float(it.get("quantity") or 0)
                if not q or not it.get("id"): continue
                f_, t_ = (d.get(frm) if frm else None), (d.get(to) if to else None)
                if kind == "adjustments": f_, t_ = (d.get(frm), None) if q < 0 else (None, d.get(to))
                rows.append((kind, int(it["id"]), int(d["id"]), str(d.get("number") or d.get("referenceNumber") or "") or None,
                             int(it.get("skuId") or 0) or None, (it.get("name") or it.get("description") or "")[:300] or None, it.get("code"),
                             abs(q), it.get("cost"), int(f_ or 0) or None, int(t_ or 0) or None, int(d.get("jobId") or 0) or None, at,
                             ((d.get("type") or d.get("transferType") or "") + (" · " if (d.get("type") or d.get("transferType")) and d.get("memo") else "") + (d.get("memo") or ""))[:500] or None,
                             d.get("active") is not False and it.get("active") is not False))
        if rows:
            cur.execute("CREATE TEMP TABLE IF NOT EXISTS _s_sh (LIKE st_stock_history) ON COMMIT DROP"); cur.execute("TRUNCATE _s_sh")
            with cur.copy("COPY _s_sh FROM STDIN") as cp:
                for r in rows: cp.write_row(r)
            cur.execute("""INSERT INTO st_stock_history SELECT DISTINCT ON (kind, line_st_id) * FROM _s_sh ORDER BY kind, line_st_id
                           ON CONFLICT (kind, line_st_id) DO UPDATE SET doc_number = EXCLUDED.doc_number, sku_st_id = EXCLUDED.sku_st_id,
                             item_name = EXCLUDED.item_name, item_code = EXCLUDED.item_code, quantity = EXCLUDED.quantity, unit_cost = EXCLUDED.unit_cost,
                             from_st = EXCLUDED.from_st, to_st = EXCLUDED.to_st, job_st_id = EXCLUDED.job_st_id, happened_at = EXCLUDED.happened_at,
                             memo = EXCLUDED.memo, active = EXCLUDED.active""")
        new_state["inv-" + kind] = {"continue_from": None, "since": (started - timedelta(hours=1)).isoformat()}
        out.append(f"{kind} {len(recs)} ({len(rows)} lines)")
    return "; ".join(out)


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
APP_SCHEMA = r"""
-- =====================================================================
-- Price book items: the name can have its own look (colour, bold, size, font) like the picture boxes,
-- and an item sold by the roll or the foot keeps its length (feet per roll / feet bought).
-- The name's look and the description's colours show everywhere the item shows (price book, print book, item page).
-- Safe to run more than once.
-- =====================================================================
ALTER TABLE public.pricebook_items ADD COLUMN IF NOT EXISTS name_style jsonb;
ALTER TABLE public.pricebook_items ADD COLUMN IF NOT EXISTS unit_length numeric(10,2);

CREATE OR REPLACE FUNCTION public.set_pb_item_look(p_item bigint, p_name_style jsonb, p_unit_length numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  UPDATE pricebook_items SET name_style = CASE WHEN p_name_style IS NULL OR p_name_style = '{}'::jsonb THEN NULL ELSE p_name_style END,
         unit_length = CASE WHEN p_unit_length > 0 THEN p_unit_length END, updated_at = now()
  WHERE id = p_item;
END $$;

-- the looks for a list of items (the price book page asks for the ones it shows)
CREATE OR REPLACE FUNCTION public.pb_item_looks(p_ids bigint[])
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public SET jit = off AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(jsonb_build_object('id', id, 'name_style', name_style, 'desc_html', description_html, 'unit_length', unit_length))
              FROM pricebook_items WHERE id = ANY(p_ids) AND (name_style IS NOT NULL OR description_html IS NOT NULL OR unit_length IS NOT NULL)), '[]'::jsonb) END
$$;

REVOKE EXECUTE ON FUNCTION public.set_pb_item_look(bigint, jsonb, numeric), public.pb_item_looks(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_pb_item_look(bigint, jsonb, numeric), public.pb_item_looks(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- Labour cost on a part: hours × number of techs × cost per hour.
-- A part with an add-on kit takes the kit's labour (the hours of everything in the kit, at the company labour rate)
-- until someone types their own numbers; then it says "pricing override" and who did it.
-- Safe to run more than once.
-- =====================================================================
ALTER TABLE public.pricebook_items ADD COLUMN IF NOT EXISTS labour_hours numeric(8,2);
ALTER TABLE public.pricebook_items ADD COLUMN IF NOT EXISTS labour_techs integer;
ALTER TABLE public.pricebook_items ADD COLUMN IF NOT EXISTS labour_rate numeric(10,2);
ALTER TABLE public.pricebook_items ADD COLUMN IF NOT EXISTS labour_set_by bigint;
ALTER TABLE public.pricebook_items ADD COLUMN IF NOT EXISTS labour_set_at timestamptz;

CREATE OR REPLACE FUNCTION public.pb_item_labour(p_item bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public SET jit = off AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE jsonb_build_object(
    'own', (SELECT CASE WHEN i.labour_hours IS NULL AND i.labour_rate IS NULL THEN NULL ELSE jsonb_build_object(
              'hours', i.labour_hours, 'techs', i.labour_techs, 'rate', i.labour_rate, 'at', i.labour_set_at,
              'by', (SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = i.labour_set_by)) END
            FROM pricebook_items i WHERE i.id = p_item),
    'kit', (SELECT CASE WHEN count(*) = 0 THEN NULL ELSE jsonb_build_object(
              'hours', round(sum(k.quantity * coalesce(c.est_labour_hours, 0)), 2),
              'names', (SELECT jsonb_agg(c2.name ORDER BY x.sequence) FROM pricebook_kit_items x JOIN pricebook_items c2 ON c2.id = x.component_item_id WHERE x.parent_item_id = p_item)) END
            FROM public.pb_kit_parts(p_item) k JOIN pricebook_items c ON c.id = k.item_id),
    'rate', (SELECT labour_cost_per_hour FROM company_settings ORDER BY id LIMIT 1)) END
$$;

CREATE OR REPLACE FUNCTION public.set_pb_item_labour(p_item bigint, p_hours numeric, p_techs integer, p_rate numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  UPDATE pricebook_items SET labour_hours = p_hours, labour_techs = p_techs, labour_rate = p_rate,
         labour_set_by = CASE WHEN p_hours IS NULL AND p_rate IS NULL THEN NULL ELSE public.current_app_user_id() END,
         labour_set_at = CASE WHEN p_hours IS NULL AND p_rate IS NULL THEN NULL ELSE now() END, updated_at = now()
  WHERE id = p_item;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pricebook_items', p_item, 'update', public.current_app_user_id(), jsonb_build_object('labour_hours', p_hours, 'labour_techs', p_techs, 'labour_rate', p_rate));
END $$;

REVOKE EXECUTE ON FUNCTION public.pb_item_labour(bigint), public.set_pb_item_labour(bigint, numeric, integer, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_item_labour(bigint), public.set_pb_item_labour(bigint, numeric, integer, numeric) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- What each technician mainly does: Maintenance, Service, Installs or Security (set on the Staff page, Technicians).
-- The customer page uses it to suggest the right tech for a call. Safe to run more than once.
-- =====================================================================
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS tech_kind text;

CREATE OR REPLACE FUNCTION public.tech_kinds()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public SET jit = off AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'name', public._emp_name(e.id), 'kind', e.tech_kind,
      'recent', EXISTS (SELECT 1 FROM visit_assignments va JOIN visits v ON v.id = va.visit_id WHERE va.employee_id = e.id AND v.scheduled_date > current_date - 120)
                OR EXISTS (SELECT 1 FROM app_users u WHERE u.employee_id = e.id AND u.active AND u.deleted_at IS NULL AND u.role = 'technician'))
      ORDER BY public._emp_name(e.id)), '[]'::jsonb) END
  FROM employees e WHERE e.active AND e.is_technician AND e.first_name NOT LIKE 'ZPast-%' AND public._emp_name(e.id) IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION public.set_tech_kind(p_employee bigint, p_kind text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.has_permission('staff.manage') OR public.current_staff_role() = 'owner') THEN RAISE EXCEPTION 'Only owners can change this'; END IF;
  IF p_kind IS NOT NULL AND p_kind NOT IN ('maintenance', 'service', 'installs', 'security') THEN RAISE EXCEPTION 'Pick Maintenance, Service, Installs or Security'; END IF;
  UPDATE employees SET tech_kind = p_kind, updated_at = now() WHERE id = p_employee;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('employees', p_employee, 'update', public.current_app_user_id(), jsonb_build_object('tech_kind', p_kind));
END $$;

REVOKE EXECUTE ON FUNCTION public.tech_kinds(), public.set_tech_kind(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tech_kinds(), public.set_tech_kind(bigint, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- Partners for sales: a tick on each partner says it can be used for sales calls and sales invoices
-- (otherwise it's only for normal invoices and billing). The booking page's "Sales Call" lists Reid plus the ticked partners.
-- Once: Rona, Costco, Vista and Hudson Restoration are ticked; Lowe's, IWS and Maytag are switched off. Safe to run more than once.
-- =====================================================================
ALTER TABLE public.partners ADD COLUMN IF NOT EXISTS sales_ok boolean NOT NULL DEFAULT false;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM audit_log WHERE table_name = 'setup' AND new_values ->> 'step' = 'sales partners') THEN
    UPDATE partners SET sales_ok = true WHERE name ~* '^(rona|costco|vista|hudson)';
    UPDATE partners SET active = false WHERE name ~* '^(lowe|iws|maytag)';
    INSERT INTO audit_log (table_name, row_id, action, new_values) VALUES ('setup', 0, 'update', jsonb_build_object('step', 'sales partners'));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.partner_sales()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE
    coalesce((SELECT jsonb_agg(jsonb_build_object('id', id, 'name', name, 'sales_ok', sales_ok) ORDER BY name) FROM partners WHERE active), '[]'::jsonb) END
$$;

CREATE OR REPLACE FUNCTION public.set_partner_sales(p_id bigint, p_on boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public._can_partner_pay() THEN RAISE EXCEPTION 'You don''t have permission to change partners'; END IF;
  UPDATE partners SET sales_ok = coalesce(p_on, false), updated_at = now() WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('partners', p_id, 'update', public.current_app_user_id(), jsonb_build_object('sales_ok', p_on));
END $$;

-- a sales call booked for a partner: the job belongs to that partner
CREATE OR REPLACE FUNCTION public.set_job_partner(p_job bigint, p_partner bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  UPDATE jobs SET partner_id = p_partner WHERE id = p_job;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('jobs', p_job, 'update', public.current_app_user_id(), jsonb_build_object('partner_id', p_partner));
END $$;

REVOKE EXECUTE ON FUNCTION public.partner_sales(), public.set_partner_sales(bigint, boolean), public.set_job_partner(bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.partner_sales(), public.set_partner_sales(bigint, boolean), public.set_job_partner(bigint, bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- Sales page: sales jobs → booked → estimate (price book items, up to 3 options) → closed deal (sold + an Install job).
-- Sales people see their own; owners see everyone's. "See invoices" is a permission an owner can give a sales person.
-- Safe to run more than once.
-- =====================================================================
INSERT INTO public.permissions (code, name, description, category, sort_order)
VALUES ('invoices.view', 'See invoices', 'Sales people: see a customer''s invoices and what they owe', 'Invoices', 61)
ON CONFLICT (code) DO NOTHING;

-- the sales jobs on the Sales page (mine, or everyone's for owners / dispatch)
CREATE OR REPLACE FUNCTION public.sales_pipeline(p_all boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public SET jit = off AS $$
  WITH me AS (SELECT public._my_employee() AS emp, public.current_app_user_id() AS uid,
                     coalesce(public.current_staff_role() = 'owner' OR public.has_permission('calls.dispatch'), false) AS boss),
  j AS (
    SELECT jb.* FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id, me
    WHERE t.job_class = 'sales' AND jb.created_at > now() - interval '18 months'
      AND (p_all AND me.boss OR jb.booked_by_user_id = me.uid OR jb.sold_by_employee_id = me.emp
           OR EXISTS (SELECT 1 FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id AND va.employee_id = me.emp))
    ORDER BY jb.created_at DESC LIMIT 400)
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb ELSE coalesce(jsonb_agg(x ORDER BY x->>'sort' DESC), '[]'::jsonb) END FROM (
    SELECT jsonb_build_object(
      'job_id', j.id, 'job_number', j.job_number, 'status', j.status, 'summary', j.summary, 'type', t.name,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = j.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', (SELECT public._emp_name(va.employee_id) FROM visit_assignments va WHERE va.visit_id = v.id ORDER BY va.role = 'lead' DESC LIMIT 1),
      'est_id', e.id, 'est_number', e.estimate_number, 'est_status', e.status, 'est_total', (SELECT max(t2.tot) FROM (SELECT sum(el.line_total) tot FROM estimate_options o JOIN estimate_lines el ON el.estimate_option_id = o.id WHERE o.estimate_id = e.id GROUP BY o.id) t2),
      'sold_total', (SELECT sum(el.line_total) FROM estimate_lines el WHERE el.estimate_option_id = e.accepted_option_id),
      'stage', CASE WHEN e.status = 'accepted' THEN 'closed' WHEN e.status IN ('lost', 'declined', 'expired') OR j.status = 'cancelled' THEN 'lost'
                    WHEN e.id IS NOT NULL THEN 'estimate' ELSE 'booked' END,
      'sort', coalesce(e.updated_at, j.created_at)) AS x
    FROM j JOIN job_types t ON t.id = j.job_type_id JOIN customers c ON c.id = j.customer_id LEFT JOIN locations l ON l.id = j.location_id
    LEFT JOIN LATERAL (SELECT * FROM visits v WHERE v.job_id = j.id ORDER BY v.visit_number DESC LIMIT 1) v ON true
    LEFT JOIN LATERAL (SELECT * FROM estimates e WHERE e.job_id = j.id ORDER BY e.id DESC LIMIT 1) e ON true) s
$$;

-- start an estimate for a sales job (or open the one it has)
CREATE OR REPLACE FUNCTION public.est_create(p_job bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE j jobs; v_id bigint;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT * INTO j FROM jobs WHERE id = p_job; IF j.id IS NULL THEN RAISE EXCEPTION 'That job no longer exists'; END IF;
  SELECT id INTO v_id FROM estimates WHERE job_id = p_job AND status NOT IN ('lost', 'declined', 'expired') ORDER BY id DESC LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  INSERT INTO estimates (estimate_number, job_id, customer_id, location_id, business_unit_id, partner_id, sold_by_employee_id, created_via, status)
  VALUES ('E' || p_job || '-' || floor(extract(epoch FROM now()))::bigint % 100000, p_job, j.customer_id, j.location_id, j.business_unit_id, j.partner_id,
          public._my_employee(), 'onsite', 'draft') RETURNING id INTO v_id;
  UPDATE estimates SET estimate_number = 'E' || v_id WHERE id = v_id;
  INSERT INTO estimate_options (estimate_id, sequence, name, is_recommended) VALUES (v_id, 1, 'Option 1', true);
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('estimates', v_id, 'insert', public.current_app_user_id(), jsonb_build_object('job_id', p_job));
  RETURN v_id;
END $$;

-- save the estimate: its options and their lines (replaces what was there). Not after it's sold or lost.
CREATE OR REPLACE FUNCTION public.est_save(p_id bigint, p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e estimates; o jsonb; ln jsonb; v_opt bigint; n int := 0; k int;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT * INTO e FROM estimates WHERE id = p_id; IF e.id IS NULL THEN RAISE EXCEPTION 'That estimate no longer exists'; END IF;
  IF e.status IN ('accepted', 'lost', 'declined', 'expired') THEN RAISE EXCEPTION 'This estimate is closed and can''t be changed'; END IF;
  IF jsonb_array_length(coalesce(p -> 'options', '[]')) > 3 THEN RAISE EXCEPTION 'Up to 3 options'; END IF;
  DELETE FROM estimate_lines WHERE estimate_option_id IN (SELECT id FROM estimate_options WHERE estimate_id = p_id);
  DELETE FROM estimate_options WHERE estimate_id = p_id;
  FOR o IN SELECT * FROM jsonb_array_elements(coalesce(p -> 'options', '[]')) LOOP
    n := n + 1;
    INSERT INTO estimate_options (estimate_id, sequence, name, description, is_recommended)
    VALUES (p_id, n, coalesce(nullif(btrim(o ->> 'name'), ''), 'Option ' || n), nullif(btrim(o ->> 'description'), ''), coalesce((o ->> 'recommended')::boolean, false))
    RETURNING id INTO v_opt;
    k := 0;
    FOR ln IN SELECT * FROM jsonb_array_elements(coalesce(o -> 'lines', '[]')) LOOP
      k := k + 1;
      INSERT INTO estimate_lines (estimate_option_id, sequence, item_id, description, quantity, unit_price, unit_cost, est_labour_hours, taxable)
      SELECT v_opt, k, i.id, coalesce(nullif(btrim(ln ->> 'description'), ''), i.name, 'Item'), coalesce((ln ->> 'qty')::numeric, 1),
             coalesce((ln ->> 'price')::numeric, i.unit_price, 0), coalesce(i.unit_cost, 0), i.est_labour_hours, coalesce(i.taxable, true)
      FROM (SELECT 1) one LEFT JOIN pricebook_items i ON i.id = nullif(ln ->> 'item_id', '')::bigint;
    END LOOP;
  END LOOP;
  UPDATE estimates SET status = CASE WHEN p ? 'sent' AND (p ->> 'sent')::boolean THEN 'sent' ELSE status END,
         sent_at = CASE WHEN p ? 'sent' AND (p ->> 'sent')::boolean AND sent_at IS NULL THEN now() ELSE sent_at END, updated_at = now() WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('estimates', p_id, 'update', public.current_app_user_id(), jsonb_build_object('options', n));
END $$;

-- closed deal: the customer picked an option. Marks it sold and makes an Install job, ready to schedule.
CREATE OR REPLACE FUNCTION public.est_close(p_id bigint, p_option bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e estimates; sj jobs; v_type bigint; ij jobs; v_name text;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT * INTO e FROM estimates WHERE id = p_id; IF e.id IS NULL THEN RAISE EXCEPTION 'That estimate no longer exists'; END IF;
  IF e.status = 'accepted' THEN RAISE EXCEPTION 'This deal is already closed'; END IF;
  SELECT name INTO v_name FROM estimate_options WHERE id = p_option AND estimate_id = p_id;
  IF v_name IS NULL THEN RAISE EXCEPTION 'Pick the option the customer chose'; END IF;
  UPDATE estimates SET status = 'accepted', accepted_option_id = p_option, accepted_at = now(), accepted_via = 'tablet',
         sold_by_employee_id = coalesce(sold_by_employee_id, public._my_employee()), updated_at = now() WHERE id = p_id;
  SELECT * INTO sj FROM jobs WHERE id = e.job_id;
  SELECT id INTO v_type FROM job_types WHERE job_class = 'install' AND active IS NOT FALSE ORDER BY (name ~* '^install x 1') DESC, (name ~* '^install') DESC, name LIMIT 1;
  INSERT INTO jobs (job_number, customer_id, location_id, job_type_id, business_unit_id, status, priority, summary, booked_by_user_id, sold_by_employee_id, partner_id)
  VALUES ('new', e.customer_id, e.location_id, v_type, coalesce(e.business_unit_id, sj.business_unit_id), 'new', 'normal',
          left('Install: ' || v_name || ' (estimate ' || e.estimate_number || ')', 200), public.current_app_user_id(), coalesce(e.sold_by_employee_id, public._my_employee()), coalesce(e.partner_id, sj.partner_id))
  RETURNING * INTO ij;
  UPDATE jobs SET job_number = ij.id::text WHERE id = ij.id RETURNING * INTO ij;
  INSERT INTO job_status_history (job_id, from_status, to_status, changed_by_user_id, note) VALUES (ij.id, NULL, 'new', public.current_app_user_id(), 'Sold on estimate ' || e.estimate_number);
  IF sj.id IS NOT NULL AND sj.status NOT IN ('completed', 'cancelled') THEN
    UPDATE jobs SET status = 'completed', completed_at = now() WHERE id = sj.id;
    INSERT INTO job_status_history (job_id, from_status, to_status, changed_by_user_id, note) VALUES (sj.id, sj.status, 'completed', public.current_app_user_id(), 'Deal closed');
  END IF;
  INSERT INTO notes (entity_type, entity_id, body, author_user_id, source)
  VALUES ('job', ij.id, 'Sold: ' || v_name || ' on estimate ' || e.estimate_number || '. Book the install from Dispatch.', public.current_app_user_id(), 'sales');
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('estimates', p_id, 'update', public.current_app_user_id(), jsonb_build_object('status', 'accepted', 'option', p_option, 'install_job', ij.id));
  RETURN jsonb_build_object('install_job_id', ij.id, 'install_job_number', ij.job_number);
END $$;

-- not sold
CREATE OR REPLACE FUNCTION public.est_lost(p_id bigint, p_reason text, p_note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  UPDATE estimates SET status = 'lost', lost_reason = CASE WHEN p_reason IN ('price', 'competitor', 'not_doing_work', 'no_response', 'financing_declined', 'other') THEN p_reason ELSE 'other' END,
         lost_note = nullif(btrim(p_note), ''), updated_at = now() WHERE id = p_id AND status <> 'accepted';
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('estimates', p_id, 'update', public.current_app_user_id(), jsonb_build_object('status', 'lost', 'reason', p_reason));
END $$;

REVOKE EXECUTE ON FUNCTION public.sales_pipeline(boolean), public.est_create(bigint), public.est_save(bigint, jsonb), public.est_close(bigint, bigint), public.est_lost(bigint, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_pipeline(boolean), public.est_create(bigint), public.est_save(bigint, jsonb), public.est_close(bigint, bigint), public.est_lost(bigint, text, text) TO authenticated;
-- sales people can always book (the app only lets them book sales calls) and look up price book items for estimates
CREATE OR REPLACE FUNCTION public.has_permission(p_code text)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT coalesce(public.current_staff_role() = 'owner', false)
      OR EXISTS (SELECT 1 FROM public.user_permissions
                 WHERE app_user_id = public.current_app_user_id() AND permission_code = p_code)
      OR (p_code = 'pricebook.view' AND EXISTS (SELECT 1 FROM public.app_users WHERE id = public.current_app_user_id() AND price_book_id IS NOT NULL))
      OR (p_code IN ('calls.book', 'pricebook.view') AND coalesce(public.current_staff_role() = 'sales', false))
$function$;

NOTIFY pgrst, 'reload schema';

-- 99zd: sales people only see invoices and payments when they have "See invoices" (invoices.view).
-- Everyone else on staff sees them as before. Safe to run more than once.
CREATE OR REPLACE FUNCTION public._can_see_invoices() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.current_staff_role() IS NOT NULL
     AND (public.current_staff_role() IS DISTINCT FROM 'sales' OR public.has_permission('invoices.view'))
$$;
REVOKE ALL ON FUNCTION public._can_see_invoices() FROM public;
GRANT EXECUTE ON FUNCTION public._can_see_invoices() TO authenticated;

DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['invoices','invoice_lines','payments','payment_applications','payment_plans','payment_plan_installments'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('DROP POLICY IF EXISTS staff_read ON public.%I', t);
      EXECUTE format('CREATE POLICY staff_read ON public.%I FOR SELECT TO authenticated USING ((SELECT public._can_see_invoices()))', t);
    END IF;
  END LOOP;
END $$;

-- 99ze: (1) Desert can be picked in Settings, and a picked theme sticks after logging in again
--       (2) sales people can add new customers
--       (3) the go-live lock: one switch (Settings, owners only), OFF until go-live.
--           When ON: purchase orders, supplier bills, supplier payments only for people with "Create POs" or "See costs",
--           and staff pay rates (hourly wage, burden, labour cost) can't be read from the staff list.
-- Safe to run more than once.

-- (1) colour themes
CREATE OR REPLACE FUNCTION public.save_my_theme(p_prefs jsonb)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_me bigint := public.current_app_user_id();
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Only staff can save colours'; END IF;
  IF coalesce(p_prefs ->> 'id', '') NOT IN ('desert', 'classic', 'night', 'warm', 'forest') THEN RAISE EXCEPTION 'Unknown colour theme'; END IF;
  IF coalesce(p_prefs ->> 'font', 'm') NOT IN ('s', 'm', 'l', 'xl') THEN RAISE EXCEPTION 'Unknown text size'; END IF;
  IF p_prefs ? 'custom' AND (jsonb_typeof(p_prefs -> 'custom') <> 'object' OR EXISTS (
       SELECT 1 FROM jsonb_each(p_prefs -> 'custom') t
       WHERE t.key NOT IN ('desert', 'classic', 'night', 'warm', 'forest') OR jsonb_typeof(t.value) <> 'object'
          OR EXISTS (SELECT 1 FROM jsonb_each_text(t.value) c
                     WHERE c.key NOT IN ('paper', 'panel', 'blue', 'ink') OR c.value !~ '^#[0-9A-Fa-f]{6}$'))) THEN
    RAISE EXCEPTION 'One of the custom colours isn''t valid';
  END IF;
  UPDATE app_users SET theme_prefs = jsonb_build_object('id', p_prefs -> 'id', 'custom', coalesce(p_prefs -> 'custom', '{}'::jsonb),
                                                       'font', coalesce(p_prefs ->> 'font', 'm'), 'v', 2)
  WHERE id = v_me;
END $function$;

-- (2) sales people: book calls, look up the price book, add customers
CREATE OR REPLACE FUNCTION public.has_permission(p_code text)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT coalesce(public.current_staff_role() = 'owner', false)
      OR EXISTS (SELECT 1 FROM public.user_permissions
                 WHERE app_user_id = public.current_app_user_id() AND permission_code = p_code)
      OR (p_code = 'pricebook.view' AND EXISTS (SELECT 1 FROM public.app_users WHERE id = public.current_app_user_id() AND price_book_id IS NOT NULL))
      OR (p_code IN ('calls.book', 'pricebook.view', 'customers.add') AND coalesce(public.current_staff_role() = 'sales', false))
$function$;

-- (3) the go-live lock
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS golive_lock boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public._golive_locked() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce((SELECT golive_lock FROM public.company_settings ORDER BY id LIMIT 1), false)
$$;
CREATE OR REPLACE FUNCTION public._can_see_buying() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.current_staff_role() IS NOT NULL
     AND (NOT public._golive_locked() OR public.has_permission('po.create') OR public.has_permission('costs.view'))
$$;
REVOKE ALL ON FUNCTION public._golive_locked(), public._can_see_buying() FROM public;
GRANT EXECUTE ON FUNCTION public._golive_locked(), public._can_see_buying() TO authenticated;

DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['purchase_orders','purchase_order_lines','supplier_invoices','third_party_supplier_payments','supplier_items'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('DROP POLICY IF EXISTS staff_read ON public.%I', t);
      EXECUTE format('CREATE POLICY staff_read ON public.%I FOR SELECT TO authenticated USING ((SELECT public._can_see_buying()))', t);
    END IF;
  END LOOP;
END $$;

-- staff pay rates: readable from the staff list only while the lock is off
CREATE OR REPLACE FUNCTION public._golive_apply_wages() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE cols text;
BEGIN
  IF public._golive_locked() THEN
    SELECT string_agg(quote_ident(column_name), ', ') INTO cols FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'employees' AND column_name NOT IN ('hourly_wage', 'burden_pct', 'labour_cost_per_hour');
    EXECUTE 'REVOKE SELECT ON public.employees FROM authenticated';
    EXECUTE 'GRANT SELECT (' || cols || ') ON public.employees TO authenticated';
  ELSE
    EXECUTE 'GRANT SELECT ON public.employees TO authenticated';
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._golive_apply_wages() FROM public, authenticated, anon;

CREATE OR REPLACE FUNCTION public.golive_lock() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$ SELECT public._golive_locked() $$;
CREATE OR REPLACE FUNCTION public.set_golive_lock(p_on boolean) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF coalesce(public.current_staff_role(), '') <> 'owner' THEN RAISE EXCEPTION 'Only an owner can change the go-live lock'; END IF;
  UPDATE public.company_settings SET golive_lock = coalesce(p_on, false), updated_at = now();
  PERFORM public._golive_apply_wages();
  RETURN public._golive_locked();
END $$;
REVOKE ALL ON FUNCTION public.golive_lock(), public.set_golive_lock(boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.golive_lock(), public.set_golive_lock(boolean) TO authenticated;

SELECT public._golive_apply_wages();

-- 99zf: the Sales page shows only install sales and the Install jobs they turned into, and only sales people's (role "Sales").
-- Safe to run more than once.
ALTER TABLE public.jobs ADD COLUMN IF NOT EXISTS from_estimate_id bigint;
CREATE INDEX IF NOT EXISTS jobs_from_estimate_idx ON public.jobs (from_estimate_id) WHERE from_estimate_id IS NOT NULL;
-- Install jobs already made by closing a deal: link them to their estimate
UPDATE public.jobs j SET from_estimate_id = a.row_id
  FROM public.audit_log a
 WHERE a.table_name = 'estimates' AND a.new_values ? 'install_job' AND (a.new_values ->> 'install_job')::bigint = j.id AND j.from_estimate_id IS NULL;

CREATE OR REPLACE FUNCTION public.est_close(p_id bigint, p_option bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e estimates; sj jobs; v_type bigint; ij jobs; v_name text;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT * INTO e FROM estimates WHERE id = p_id; IF e.id IS NULL THEN RAISE EXCEPTION 'That estimate no longer exists'; END IF;
  IF e.status = 'accepted' THEN RAISE EXCEPTION 'This deal is already closed'; END IF;
  SELECT name INTO v_name FROM estimate_options WHERE id = p_option AND estimate_id = p_id;
  IF v_name IS NULL THEN RAISE EXCEPTION 'Pick the option the customer chose'; END IF;
  UPDATE estimates SET status = 'accepted', accepted_option_id = p_option, accepted_at = now(), accepted_via = 'tablet',
         sold_by_employee_id = coalesce(sold_by_employee_id, public._my_employee()), updated_at = now() WHERE id = p_id;
  SELECT * INTO sj FROM jobs WHERE id = e.job_id;
  SELECT id INTO v_type FROM job_types WHERE job_class = 'install' AND active IS NOT FALSE ORDER BY (name ~* '^install x 1') DESC, (name ~* '^install') DESC, name LIMIT 1;
  INSERT INTO jobs (job_number, customer_id, location_id, job_type_id, business_unit_id, status, priority, summary, booked_by_user_id, sold_by_employee_id, partner_id, from_estimate_id)
  VALUES ('new', e.customer_id, e.location_id, v_type, coalesce(e.business_unit_id, sj.business_unit_id), 'new', 'normal',
          left('Install: ' || v_name || ' (estimate ' || e.estimate_number || ')', 200), public.current_app_user_id(), coalesce(e.sold_by_employee_id, public._my_employee()), coalesce(e.partner_id, sj.partner_id), e.id)
  RETURNING * INTO ij;
  UPDATE jobs SET job_number = ij.id::text WHERE id = ij.id RETURNING * INTO ij;
  INSERT INTO job_status_history (job_id, from_status, to_status, changed_by_user_id, note) VALUES (ij.id, NULL, 'new', public.current_app_user_id(), 'Sold on estimate ' || e.estimate_number);
  IF sj.id IS NOT NULL AND sj.status NOT IN ('completed', 'cancelled') THEN
    UPDATE jobs SET status = 'completed', completed_at = now() WHERE id = sj.id;
    INSERT INTO job_status_history (job_id, from_status, to_status, changed_by_user_id, note) VALUES (sj.id, sj.status, 'completed', public.current_app_user_id(), 'Deal closed');
  END IF;
  INSERT INTO notes (entity_type, entity_id, body, author_user_id, source)
  VALUES ('job', ij.id, 'Sold: ' || v_name || ' on estimate ' || e.estimate_number || '. Book the install from Dispatch.', public.current_app_user_id(), 'sales');
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('estimates', p_id, 'update', public.current_app_user_id(), jsonb_build_object('status', 'accepted', 'option', p_option, 'install_job', ij.id));
  RETURN jsonb_build_object('install_job_id', ij.id, 'install_job_number', ij.job_number);
END $$;


-- the install kinds of sales call (not walk-throughs, gas piping or pool heaters)
CREATE OR REPLACE FUNCTION public._is_install_sale(p_type_name text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT coalesce(p_type_name ~* '(hvac quote|quote for a/?c|quote for furnace)', false) $$;

CREATE OR REPLACE FUNCTION public.sales_pipeline(p_all boolean DEFAULT false)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH me AS (SELECT public._my_employee() AS emp, public.current_app_user_id() AS uid,
                     coalesce(public.current_staff_role() = 'owner' OR public.has_permission('calls.dispatch'), false) AS boss),
  sp AS (SELECT id AS uid, employee_id AS emp FROM app_users WHERE role = 'sales'),          -- the sales people
  j AS (
    SELECT jb.* FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id, me
    WHERE t.job_class = 'sales' AND public._is_install_sale(t.name) AND jb.created_at > now() - interval '18 months'
      AND CASE WHEN me.boss
               THEN EXISTS (SELECT 1 FROM sp WHERE sp.uid = jb.booked_by_user_id OR sp.emp = jb.sold_by_employee_id
                              OR sp.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))
               ELSE jb.booked_by_user_id = me.uid OR jb.sold_by_employee_id = me.emp
                    OR EXISTS (SELECT 1 FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id AND va.employee_id = me.emp) END
    ORDER BY jb.created_at DESC LIMIT 400),
  rows AS (
    SELECT jsonb_build_object(
      'job_id', j.id, 'job_number', j.job_number, 'status', j.status, 'summary', j.summary, 'type', t.name,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = j.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', (SELECT public._emp_name(va.employee_id) FROM visit_assignments va WHERE va.visit_id = v.id ORDER BY va.role = 'lead' DESC LIMIT 1),
      'est_id', e.id, 'est_number', e.estimate_number, 'est_status', e.status, 'est_total', (SELECT max(t2.tot) FROM (SELECT sum(el.line_total) tot FROM estimate_options o JOIN estimate_lines el ON el.estimate_option_id = o.id WHERE o.estimate_id = e.id GROUP BY o.id) t2),
      'sold_total', (SELECT sum(el.line_total) FROM estimate_lines el WHERE el.estimate_option_id = e.accepted_option_id),
      'stage', CASE WHEN e.status = 'accepted' THEN 'closed' WHEN e.status IN ('lost', 'declined', 'expired') OR j.status = 'cancelled' THEN 'lost'
                    WHEN e.id IS NOT NULL THEN 'estimate' ELSE 'booked' END,
      'sort', coalesce(e.updated_at, j.created_at)) AS x, e.id AS est
    FROM j JOIN job_types t ON t.id = j.job_type_id JOIN customers c ON c.id = j.customer_id LEFT JOIN locations l ON l.id = j.location_id
    LEFT JOIN LATERAL (SELECT * FROM visits v WHERE v.job_id = j.id ORDER BY v.visit_number DESC LIMIT 1) v ON true
    LEFT JOIN LATERAL (SELECT * FROM estimates e WHERE e.job_id = j.id ORDER BY e.id DESC LIMIT 1) e ON true),
  -- the Install jobs those deals turned into
  inst AS (
    SELECT jsonb_build_object(
      'job_id', ij.id, 'job_number', ij.job_number, 'status', ij.status, 'summary', ij.summary, 'type', t.name,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = ij.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', public._emp_name(ij.sold_by_employee_id),
      'est_id', e.id, 'est_number', e.estimate_number, 'est_status', e.status,
      'sold_total', (SELECT sum(el.line_total) FROM estimate_lines el WHERE el.estimate_option_id = e.accepted_option_id),
      'stage', 'install', 'sort', ij.created_at) AS x
    FROM rows r JOIN jobs ij ON ij.from_estimate_id = r.est JOIN estimates e ON e.id = r.est
    JOIN job_types t ON t.id = ij.job_type_id JOIN customers c ON c.id = ij.customer_id LEFT JOIN locations l ON l.id = ij.location_id
    LEFT JOIN LATERAL (SELECT * FROM visits v WHERE v.job_id = ij.id ORDER BY v.visit_number DESC LIMIT 1) v ON true)
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb
              ELSE coalesce((SELECT jsonb_agg(x ORDER BY x->>'sort' DESC) FROM (SELECT x FROM rows UNION ALL SELECT x FROM inst) a), '[]'::jsonb) END
$function$;
REVOKE EXECUTE ON FUNCTION public.sales_pipeline(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_pipeline(boolean) TO authenticated;

-- 99zg: Walk site visits booked from the Sales page show on the Sales page too. Safe to run more than once.
CREATE OR REPLACE FUNCTION public._is_install_sale(p_type_name text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT coalesce(p_type_name ~* '(hvac quote|quote for a/?c|quote for furnace|walk\s*site)', false) $$;
"""


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
        fail("Couldn't connect to the database (" + str(e).strip().splitlines()[-1][:200] + "). "
             "Check DB_HOST, DB_PORT, DB_USER and DB_PASSWORD (on GitHub use the Session pooler details from Supabase).")
    cur = conn.cursor()
    cur.execute("SET statement_timeout = 0")
    cur.execute("SELECT to_regclass('public.st_sync_state') IS NOT NULL")
    if not cur.fetchone()[0]:
        fail("Run app\\setup\\RUN SETUP.bat first (it adds setup file 24), then run this again.")
    # only one sync at a time
    cur.execute("SELECT pg_try_advisory_lock(80451)")
    if not cur.fetchone()[0]:
        fail("Another sync is running right now. Try again in a few minutes.")
    cur.execute("INSERT INTO st_sync_runs (source) VALUES (%s) RETURNING id", (args.source,))
    run_id = cur.fetchone()[0]; conn.commit()
    # small app database changes that don't hold customer data, so the app works even before RUN SETUP NOW.bat is run (safe to repeat)
    try:
        cur.execute(APP_SCHEMA); conn.commit(); log("App database pieces checked (item looks, labour).")
        cur.execute("SELECT to_regprocedure('public.set_pb_item_look(bigint,jsonb,numeric)') IS NOT NULL AND to_regprocedure('public.set_pb_item_labour(bigint,numeric,integer,numeric)') IS NOT NULL AND to_regprocedure('public.set_tech_kind(bigint,text)') IS NOT NULL AND to_regprocedure('public.set_job_partner(bigint,bigint)') IS NOT NULL AND to_regprocedure('public.est_close(bigint,bigint)') IS NOT NULL AND to_regprocedure('public._can_see_invoices()') IS NOT NULL AND to_regprocedure('public.set_golive_lock(boolean)') IS NOT NULL AND to_regprocedure('public._is_install_sale(text)') IS NOT NULL")
        if os.environ.get("GITHUB_ACTIONS"): print(f"::notice::Item looks ready in the database: {cur.fetchone()[0]}", flush=True)
    except Exception as e:
        conn.rollback(); log(f"  App database pieces not added: {str(e)[:200]}")
        if os.environ.get("GITHUB_ACTIONS"): print(f"::notice::Item looks not added: {str(e)[:200]}", flush=True)

    try:
        new_state = {}
        cur.execute("SELECT endpoint, continue_from, since FROM st_sync_state")
        state = {e: {"continue_from": c, "since": s.isoformat() if s else None} for e, c, s in cur.fetchall()}
        # one time: go back over every change since the export (the first run may have started from the wrong place)
        cur.execute("SELECT 1 FROM st_sync_state WHERE endpoint = 'reseed-from-export'")
        if state and not cur.fetchone() and not args.from_files and not QUIET:
            seed = seed_from_export()
            if seed and len(seed) > 5:
                for k, v in seed.items():
                    if k != "installed-equipment": state[k] = v
                state["installed-equipment"] = seed["installed-equipment"]
                log("Going back over everything since the export once, to catch anything missed.")
                new_state["reseed-from-export"] = {"continue_from": None, "since": started.isoformat()}
        if not state and not args.from_files:
            state = seed_from_export()
            if not state:
                raise RuntimeError("This is the first sync and there's no ServiceTitan export folder to start from. "
                                   "Run SYNC NOW.bat once on the computer that has the export_... folder.")
            new_state["reseed-from-export"] = {"continue_from": None, "since": started.isoformat()}
        st = ST(st_s) if not args.from_files else None
        delta = {}
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
        if st:
            cur.execute("SAVEPOINT pos")
            try:
                n_po = sync_purchase_orders(cur, st, state, new_state)
                if n_po: log(f"Purchase orders: {n_po} brought in or updated.")
                cur.execute("SAVEPOINT inv")
                try:
                    inv = sync_inventory(cur, st, state, new_state)
                    log("Stock: " + inv)
                    if os.environ.get("GITHUB_ACTIONS"): print(f"::notice::Stock from ServiceTitan: {inv}", flush=True)
                    cur.execute("RELEASE SAVEPOINT inv")
                except Exception as e:   # never let stock stop the rest of the sync
                    cur.execute("ROLLBACK TO SAVEPOINT inv")
                    for k in [k for k in new_state if k.startswith("inv-") and k != "inv-probe"]: new_state.pop(k, None)
                    print(f"::notice::Stock skipped this time: {str(e)[:300]}", flush=True)
                if os.environ.get("GITHUB_ACTIONS") and not (state.get("inv-probe") or {}).get("since"):   # one time: which inventory lists we can read
                    try:
                        import st_probe_lib; st_probe_lib.run(st)
                        new_state["inv-probe"] = {"continue_from": None, "since": started.isoformat()}
                    except Exception as e:
                        print(f"::notice::Inventory check failed: {str(e)[:200]}", flush=True)
                if os.environ.get("GITHUB_ACTIONS"):   # counts only, for the Actions page
                    cur.execute("SELECT coalesce(string_agg(y || ': ' || n, ', ' ORDER BY y), 'none') FROM (SELECT extract(year FROM coalesce(ordered_at, created_at))::int y, count(*) n FROM purchase_orders GROUP BY 1) t")
                    print(f"::notice::Purchase orders in the app by year: {cur.fetchone()[0]}", flush=True)
                    if "po-backfill" not in new_state and not (state.get("po-backfill") or {}).get("since"):
                        print("::notice::Older purchase orders: ServiceTitan's PO list didn't answer this time; it will try again next run.", flush=True)
                cur.execute("RELEASE SAVEPOINT pos")
            except Exception as e:   # never let POs stop the rest of the sync
                cur.execute("ROLLBACK TO SAVEPOINT pos")
                new_state.pop("purchase-orders", None); new_state.pop("po-backfill", None)
                log("  Purchase orders skipped this time: " + ("see the Settings page" if QUIET else str(e)[:300]))
        if st:
            # the techs on calls from 2 days ago to 6 weeks ahead always match ServiceTitan; the first time, go back 6 months
            cur.execute("SELECT 1 FROM st_sync_state WHERE endpoint = 'techs-matched'")
            back = 2 if cur.fetchone() else 183
            res = match_assignments(cur, st, (started - timedelta(days=back)).date(), (started + timedelta(days=42)).date())
            if res is not None:
                if res[0] or res[1]: log(f"Techs on calls brought in line with ServiceTitan: {res[0]} added, {res[1]} taken off.")
                new_state["techs-matched"] = {"continue_from": None, "since": started.isoformat()}
        for name, v in new_state.items():
            cur.execute("INSERT INTO st_sync_state (endpoint, continue_from, since, updated_at) VALUES (%s, %s, %s, now()) "
                        "ON CONFLICT (endpoint) DO UPDATE SET continue_from = EXCLUDED.continue_from, since = EXCLUDED.since, updated_at = now()",
                        (name, v["continue_from"], v["since"]))
        summary = {"changed": {n: len(r) for n, r in delta.items() if r and n not in ("employees", "technicians", "job-types", "business-units", "membership-types")},
                   "saved": counts, "removed": gone, "notes_added": notes, "skipped": report.get("skipped", {}),
                   "api_calls": st.calls if st else 0}
        cur.execute("UPDATE st_sync_runs SET finished_at = now(), ok = true, summary = %s WHERE id = %s", (json.dumps(summary), run_id))
        conn.commit()
        # one-time repair of calls loaded without their tech (only where the export folder is on this computer)
        cur.execute("SELECT 1 FROM st_sync_state WHERE endpoint = 'backfill-assignments'")
        if not cur.fetchone() and not QUIET:
            res = backfill_assignments(cur, args.from_files)
            if res is not None:
                log(f"Repaired {res[0]} calls that were missing their tech" + (f" ({res[1]} techs still unknown to ServiceTitan's staff list)" if res[1] else "") + ".")
                cur.execute("INSERT INTO st_sync_state (endpoint, since, updated_at) VALUES ('backfill-assignments', now(), now()) ON CONFLICT DO NOTHING")
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
        if QUIET:
            safe = str(e) if isinstance(e, RuntimeError) and str(e).startswith(("ServiceTitan", "This is the first sync")) else type(e).__name__
            fail(f"Stopped ({safe[:300]}). The full reason is on the app's Settings page, under ServiceTitan sync.")
        log(f"Stopped: {e}")
        sys.exit(1)
    finally:
        try: cur.execute("SELECT pg_advisory_unlock(80451)"); conn.commit()
        except Exception: pass


def backfill_assignments(cur, folder=None):
    """One-time repair: techs who were missing from ServiceTitan's staff list in the export (e.g. Kane) had their calls
    loaded without them. Put back every call-to-tech link from the export's saved pages, if that tech and call now exist."""
    if not folder:
        exp = latest_export()
        if not exp: return None
        folder = os.path.join(exp, "raw-json")
    pages = sorted(glob.glob(os.path.join(folder, "appointment-assignments_*.json")))
    if not pages: return None
    rows = {}
    for pth in pages:
        for r in json.load(open(pth, encoding="utf-8")).get("data") or []:
            if r.get("active") is not False and r.get("appointmentId") and r.get("technicianId"):
                rows[r["id"]] = (r["id"], int(r["appointmentId"]), int(r["technicianId"]), r.get("assignedOn") or "")
    cur.execute("DROP TABLE IF EXISTS _s_aa")
    cur.execute("CREATE TEMP TABLE _s_aa (st_id bigint, visit_id bigint, employee_id bigint, assigned text) ON COMMIT DROP")
    with cur.copy("COPY _s_aa FROM STDIN") as cp:
        for r in rows.values(): cp.write_row(r)
    cur.execute("""
        INSERT INTO visit_assignments (visit_id, employee_id, role, st_id)
        SELECT DISTINCT ON (a.visit_id, a.employee_id) a.visit_id, a.employee_id,
               CASE WHEN EXISTS (SELECT 1 FROM visit_assignments x WHERE x.visit_id = a.visit_id) THEN 'helper'
                    WHEN row_number() OVER (PARTITION BY a.visit_id ORDER BY a.assigned) = 1 THEN 'lead' ELSE 'helper' END,
               a.st_id
        FROM _s_aa a
        WHERE EXISTS (SELECT 1 FROM visits v WHERE v.id = a.visit_id)
          AND EXISTS (SELECT 1 FROM employees e WHERE e.id = a.employee_id)
          AND NOT EXISTS (SELECT 1 FROM visit_assignments x WHERE x.st_id = a.st_id)
          AND NOT EXISTS (SELECT 1 FROM visit_assignments x WHERE x.visit_id = a.visit_id AND x.employee_id = a.employee_id)
        ORDER BY a.visit_id, a.employee_id, a.assigned
        ON CONFLICT DO NOTHING""")
    added = cur.rowcount
    cur.execute("""SELECT count(DISTINCT a.employee_id) FROM _s_aa a WHERE NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = a.employee_id)""")
    still_missing = cur.fetchone()[0]
    return added, still_missing


def pull_export_marker_only(st, path):
    """No marker yet for this feed: read through to the end once, just to get a starting point."""
    return pull_export(st, path, None)


def settings_db_only():
    if os.environ.get("DB_HOST"):
        return {k: os.environ.get(k, "") for k in ("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD", "DB_SSLMODE")}
    return read_kv(find_file("supabase-settings.txt"))


if __name__ == "__main__":
    main()

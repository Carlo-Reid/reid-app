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
               coalesce(nullif(p.created, '')::timestamptz, nullif(p.ordered, '')::timestamptz, now())
        FROM (SELECT DISTINCT ON (st_id) * FROM _s_po ORDER BY st_id) p
        LEFT JOIN jobs j ON j.id = p.job LEFT JOIN employees e ON e.id = p.tech
        ON CONFLICT (st_id) WHERE st_id IS NOT NULL DO UPDATE SET supplier_id = EXCLUDED.supplier_id, purpose = EXCLUDED.purpose,
          job_id = EXCLUDED.job_id, status = EXCLUDED.status, ordered_by_employee_id = EXCLUDED.ordered_by_employee_id,
          ordered_at = EXCLUDED.ordered_at, expected_on = EXCLUDED.expected_on, supplier_reference = EXCLUDED.supplier_reference,
          notes = EXCLUDED.notes, description = EXCLUDED.description, amount = EXCLUDED.amount,
          created_at = least(purchase_orders.created_at, EXCLUDED.created_at, coalesce(EXCLUDED.ordered_at, EXCLUDED.created_at))""")
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

-- 99zh: each sales person sees only their own Sales page, unless an owner lets them see someone else's.
-- Owners and dispatchers can always see any sales person's page (and everyone's). Safe to run more than once.
CREATE TABLE IF NOT EXISTS public.sales_viewers (
  viewer_user_id bigint NOT NULL REFERENCES public.app_users(id) ON DELETE CASCADE,
  seller_user_id bigint NOT NULL REFERENCES public.app_users(id) ON DELETE CASCADE,
  granted_by_user_id bigint, granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (viewer_user_id, seller_user_id));
ALTER TABLE public.sales_viewers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sales_viewers FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._sales_boss() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(public.current_staff_role() = 'owner' OR public.has_permission('calls.dispatch'), false) $$;

-- the names in the drop-down: owners/dispatchers get every sales person; a sales person gets themself plus the ones they're allowed
CREATE OR REPLACE FUNCTION public.sales_people() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH me AS (SELECT public.current_app_user_id() AS uid, public._sales_boss() AS boss)
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'name', coalesce(public._emp_name(u.employee_id), u.login_email::text), 'me', u.id = me.uid,
           'can_see', (SELECT coalesce(jsonb_agg(v.seller_user_id), '[]'::jsonb) FROM sales_viewers v WHERE v.viewer_user_id = u.id))
         ORDER BY u.id <> me.uid, coalesce(public._emp_name(u.employee_id), u.login_email::text)), '[]'::jsonb)
  FROM app_users u, me
  WHERE u.role = 'sales' AND u.active AND public.current_staff_role() IS NOT NULL
    AND (me.boss OR u.id = me.uid OR EXISTS (SELECT 1 FROM sales_viewers v WHERE v.viewer_user_id = me.uid AND v.seller_user_id = u.id)) $$;

-- owners only: let one sales person see another's page (or stop it)
CREATE OR REPLACE FUNCTION public.set_sales_viewer(p_viewer bigint, p_seller bigint, p_on boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF coalesce(public.current_staff_role(), '') <> 'owner' THEN RAISE EXCEPTION 'Only an owner can change who sees which sales pages'; END IF;
  IF p_viewer = p_seller THEN RETURN; END IF;
  IF p_on THEN INSERT INTO sales_viewers (viewer_user_id, seller_user_id, granted_by_user_id) VALUES (p_viewer, p_seller, public.current_app_user_id()) ON CONFLICT DO NOTHING;
  ELSE DELETE FROM sales_viewers WHERE viewer_user_id = p_viewer AND seller_user_id = p_seller; END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('sales_viewers', p_viewer, CASE WHEN p_on THEN 'insert' ELSE 'delete' END, public.current_app_user_id(), jsonb_build_object('viewer', p_viewer, 'seller', p_seller));
END $$;

CREATE OR REPLACE FUNCTION public.sales_list(p_seller bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH me AS (SELECT public._my_employee() AS emp, public.current_app_user_id() AS uid, public._sales_boss() AS boss),
  who AS (   -- whose jobs: one sales person (p_seller), or everyone (owners/dispatchers with no p_seller)
    SELECT CASE WHEN p_seller IS NULL AND me.boss THEN NULL ELSE coalesce(p_seller, me.uid) END AS seller FROM me),
  ok AS (SELECT (me.boss OR who.seller = me.uid OR EXISTS (SELECT 1 FROM sales_viewers v WHERE v.viewer_user_id = me.uid AND v.seller_user_id = who.seller)) AS ok FROM me, who),
  tgt AS (SELECT u.id AS uid, u.employee_id AS emp FROM app_users u, who WHERE u.id = who.seller),
  sp AS (SELECT id AS uid, employee_id AS emp FROM app_users WHERE role = 'sales'),          -- the sales people
  j AS (
    SELECT jb.* FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id, me
    WHERE t.job_class = 'sales' AND public._is_install_sale(t.name) AND jb.created_at > now() - interval '18 months'
      AND (SELECT ok FROM ok)
      AND CASE WHEN (SELECT seller FROM who) IS NULL
               -- everyone: jobs of the sales people, and sales jobs booked in this app by the office (not old ServiceTitan ones)
               THEN EXISTS (SELECT 1 FROM sp WHERE sp.uid = jb.booked_by_user_id OR sp.emp = jb.sold_by_employee_id
                              OR sp.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))
                    OR EXISTS (SELECT 1 FROM app_users u WHERE u.id = jb.booked_by_user_id AND u.role <> 'technician')
               ELSE EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = jb.booked_by_user_id OR tgt.emp = jb.sold_by_employee_id
                              OR tgt.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id)) END
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

-- the old list (everyone's for owners) now follows the same rules
CREATE OR REPLACE FUNCTION public.sales_pipeline(p_all boolean DEFAULT false) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$ SELECT public.sales_list(NULL) $$;

REVOKE EXECUTE ON FUNCTION public.sales_list(bigint), public.sales_pipeline(boolean), public.sales_people(), public.set_sales_viewer(bigint, bigint, boolean), public._sales_boss() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_list(bigint), public.sales_pipeline(boolean), public.sales_people(), public.set_sales_viewer(bigint, bigint, boolean), public._sales_boss() TO authenticated;

-- 99zi: when the office books a sales job for a sales person (from the Sales page), it goes on that sales person's page.
-- Safe to run more than once.
ALTER TABLE public.jobs ADD COLUMN IF NOT EXISTS sales_user_id bigint REFERENCES public.app_users(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS jobs_sales_user_idx ON public.jobs (sales_user_id) WHERE sales_user_id IS NOT NULL;

-- owners/dispatchers pick any sales person; a sales person can only put a job on their own page
CREATE OR REPLACE FUNCTION public.set_job_seller(p_job bigint, p_user bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  IF NOT public._sales_boss() AND p_user IS DISTINCT FROM public.current_app_user_id() THEN RAISE EXCEPTION 'You can only put sales jobs on your own page'; END IF;
  IF p_user IS NOT NULL AND NOT EXISTS (SELECT 1 FROM app_users WHERE id = p_user AND role = 'sales') THEN RAISE EXCEPTION 'That person is not a sales person'; END IF;
  UPDATE jobs SET sales_user_id = p_user, updated_at = now() WHERE id = p_job;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('jobs', p_job, 'update', public.current_app_user_id(), jsonb_build_object('sales_user_id', p_user));
END $$;
REVOKE EXECUTE ON FUNCTION public.set_job_seller(bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_job_seller(bigint, bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.sales_list(p_seller bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH me AS (SELECT public._my_employee() AS emp, public.current_app_user_id() AS uid, public._sales_boss() AS boss),
  who AS (   -- whose jobs: one sales person (p_seller), or everyone (owners/dispatchers with no p_seller)
    SELECT CASE WHEN p_seller IS NULL AND me.boss THEN NULL ELSE coalesce(p_seller, me.uid) END AS seller FROM me),
  ok AS (SELECT (me.boss OR who.seller = me.uid OR EXISTS (SELECT 1 FROM sales_viewers v WHERE v.viewer_user_id = me.uid AND v.seller_user_id = who.seller)) AS ok FROM me, who),
  tgt AS (SELECT u.id AS uid, u.employee_id AS emp FROM app_users u, who WHERE u.id = who.seller),
  sp AS (SELECT id AS uid, employee_id AS emp FROM app_users WHERE role = 'sales'),          -- the sales people
  j AS (
    SELECT jb.* FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id, me
    WHERE t.job_class = 'sales' AND public._is_install_sale(t.name) AND jb.created_at > now() - interval '18 months'
      AND (SELECT ok FROM ok)
      AND CASE WHEN (SELECT seller FROM who) IS NULL
               -- everyone: jobs of the sales people, and sales jobs booked in this app by the office (not old ServiceTitan ones)
               THEN jb.sales_user_id IS NOT NULL
                    OR EXISTS (SELECT 1 FROM sp WHERE sp.uid = jb.booked_by_user_id OR sp.emp = jb.sold_by_employee_id
                              OR sp.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))
                    OR EXISTS (SELECT 1 FROM app_users u WHERE u.id = jb.booked_by_user_id AND u.role <> 'technician')
               ELSE EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = jb.sales_user_id OR (jb.sales_user_id IS NULL AND (tgt.uid = jb.booked_by_user_id OR tgt.emp = jb.sold_by_employee_id))
                              OR (jb.sales_user_id IS NULL AND tgt.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))) END
    ORDER BY jb.created_at DESC LIMIT 400),
  rows AS (
    SELECT jsonb_build_object(
      'job_id', j.id, 'job_number', j.job_number, 'status', j.status, 'summary', j.summary, 'type', t.name,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = j.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', (SELECT public._emp_name(va.employee_id) FROM visit_assignments va WHERE va.visit_id = v.id ORDER BY va.role = 'lead' DESC LIMIT 1),
      'sales_person', (SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = coalesce(j.sales_user_id, CASE WHEN EXISTS (SELECT 1 FROM app_users b WHERE b.id = j.booked_by_user_id AND b.role = 'sales') THEN j.booked_by_user_id END)),
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

REVOKE EXECUTE ON FUNCTION public.sales_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_list(bigint) TO authenticated;

-- 99zj: colours and text size can be saved for all pages, or just for one page. Safe to run more than once.
CREATE OR REPLACE FUNCTION public.save_my_theme(p_prefs jsonb)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_me bigint := public.current_app_user_id(); v_pages jsonb := '{}'::jsonb; k text; v jsonb;
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
  -- one page's own look: { "<page>": { "id": theme, "font": size } }, only known themes and sizes are kept
  IF jsonb_typeof(p_prefs -> 'pages') = 'object' THEN
    FOR k, v IN SELECT * FROM jsonb_each(p_prefs -> 'pages') LOOP
      IF k ~ '^[a-z0-9-]{1,40}$' AND jsonb_typeof(v) = 'object' THEN
        v_pages := v_pages || jsonb_build_object(k, jsonb_strip_nulls(jsonb_build_object(
          'id', CASE WHEN v ->> 'id' IN ('desert', 'classic', 'night', 'warm', 'forest') THEN v ->> 'id' END,
          'font', CASE WHEN v ->> 'font' IN ('s', 'm', 'l', 'xl') THEN v ->> 'font' END)));
      END IF;
    END LOOP;
  END IF;
  UPDATE app_users SET theme_prefs = jsonb_build_object('id', p_prefs -> 'id', 'custom', coalesce(p_prefs -> 'custom', '{}'::jsonb),
                                                       'font', coalesce(p_prefs ->> 'font', 'm'), 'pages', v_pages, 'v', 2)
  WHERE id = v_me;
END $function$;

-- 99zk: an estimate can be cancelled (it and its sales job leave the Sales page). Safe to run more than once.
ALTER TABLE public.estimates ADD COLUMN IF NOT EXISTS cancelled_at timestamptz;
ALTER TABLE public.estimates ADD COLUMN IF NOT EXISTS cancelled_by_user_id bigint;

CREATE OR REPLACE FUNCTION public.est_cancel(p_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e estimates; sj jobs;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT * INTO e FROM estimates WHERE id = p_id; IF e.id IS NULL THEN RAISE EXCEPTION 'That estimate no longer exists'; END IF;
  IF e.status = 'accepted' THEN RAISE EXCEPTION 'This deal is already closed, so it can''t be cancelled'; END IF;
  UPDATE estimates SET cancelled_at = now(), cancelled_by_user_id = public.current_app_user_id(), status = CASE WHEN status IN ('draft', 'sent', 'viewed') THEN 'declined' ELSE status END,
         lost_note = coalesce(lost_note, 'Cancelled'), updated_at = now() WHERE id = p_id;
  SELECT * INTO sj FROM jobs WHERE id = e.job_id;
  -- the sales job goes too, unless work already happened on it
  IF sj.id IS NOT NULL AND sj.status NOT IN ('completed', 'cancelled') AND NOT EXISTS (SELECT 1 FROM invoices WHERE job_id = sj.id) THEN
    UPDATE jobs SET status = 'cancelled' WHERE id = sj.id;
    INSERT INTO job_status_history (job_id, from_status, to_status, changed_by_user_id, note) VALUES (sj.id, sj.status, 'cancelled', public.current_app_user_id(), 'Estimate ' || e.estimate_number || ' cancelled');
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('estimates', p_id, 'update', public.current_app_user_id(), jsonb_build_object('cancelled', true));
END $$;
REVOKE EXECUTE ON FUNCTION public.est_cancel(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_cancel(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.sales_list(p_seller bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH me AS (SELECT public._my_employee() AS emp, public.current_app_user_id() AS uid, public._sales_boss() AS boss),
  who AS (   -- whose jobs: one sales person (p_seller), or everyone (owners/dispatchers with no p_seller)
    SELECT CASE WHEN p_seller IS NULL AND me.boss THEN NULL ELSE coalesce(p_seller, me.uid) END AS seller FROM me),
  ok AS (SELECT (me.boss OR who.seller = me.uid OR EXISTS (SELECT 1 FROM sales_viewers v WHERE v.viewer_user_id = me.uid AND v.seller_user_id = who.seller)) AS ok FROM me, who),
  tgt AS (SELECT u.id AS uid, u.employee_id AS emp FROM app_users u, who WHERE u.id = who.seller),
  sp AS (SELECT id AS uid, employee_id AS emp FROM app_users WHERE role = 'sales'),          -- the sales people
  j AS (
    SELECT jb.* FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id, me
    WHERE t.job_class = 'sales' AND public._is_install_sale(t.name) AND jb.created_at > now() - interval '18 months'
      AND (SELECT ok FROM ok)
      AND NOT EXISTS (SELECT 1 FROM estimates ec WHERE ec.job_id = jb.id AND ec.cancelled_at IS NOT NULL)   -- cancelled estimates leave the Sales page
      AND CASE WHEN (SELECT seller FROM who) IS NULL
               -- everyone: jobs of the sales people, and sales jobs booked in this app by the office (not old ServiceTitan ones)
               THEN jb.sales_user_id IS NOT NULL
                    OR EXISTS (SELECT 1 FROM sp WHERE sp.uid = jb.booked_by_user_id OR sp.emp = jb.sold_by_employee_id
                              OR sp.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))
                    OR EXISTS (SELECT 1 FROM app_users u WHERE u.id = jb.booked_by_user_id AND u.role <> 'technician')
               ELSE EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = jb.sales_user_id OR (jb.sales_user_id IS NULL AND (tgt.uid = jb.booked_by_user_id OR tgt.emp = jb.sold_by_employee_id))
                              OR (jb.sales_user_id IS NULL AND tgt.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))) END
    ORDER BY jb.created_at DESC LIMIT 400),
  rows AS (
    SELECT jsonb_build_object(
      'job_id', j.id, 'job_number', j.job_number, 'status', j.status, 'summary', j.summary, 'type', t.name,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = j.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', (SELECT public._emp_name(va.employee_id) FROM visit_assignments va WHERE va.visit_id = v.id ORDER BY va.role = 'lead' DESC LIMIT 1),
      'sales_person', (SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = coalesce(j.sales_user_id, CASE WHEN EXISTS (SELECT 1 FROM app_users b WHERE b.id = j.booked_by_user_id AND b.role = 'sales') THEN j.booked_by_user_id END)),
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

REVOKE EXECUTE ON FUNCTION public.sales_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_list(bigint) TO authenticated;

-- 99zl: (1) the stock import matches item codes fast (it timed out on the full price book)
--       (2) purchase orders from ServiceTitan keep the date they were made, so older years show on the POs page
-- Safe to run more than once.

-- (1) look items up by code or name with an index, instead of reading the whole price book for every line
CREATE INDEX IF NOT EXISTS pricebook_items_lsku_idx ON public.pricebook_items (lower(btrim(sku)));
CREATE INDEX IF NOT EXISTS pricebook_items_lname_idx ON public.pricebook_items (lower(btrim(name)));
CREATE OR REPLACE FUNCTION public.stock_match_items(p_codes text[])
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH k AS (SELECT DISTINCT ON (lower(btrim(code))) code, lower(btrim(code)) lc FROM unnest(p_codes) code WHERE btrim(coalesce(code, '')) <> '')
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN '[]'::jsonb
              ELSE coalesce(jsonb_agg(jsonb_build_object('code', k.code, 'id', m.id, 'name', m.name)), '[]') END
  FROM k JOIN LATERAL (
    SELECT x.id, x.name FROM (
      SELECT p.id, p.name, p.track_inventory, p.item_type, 0 AS pri FROM pricebook_items p WHERE lower(btrim(p.sku)) = k.lc AND p.active IS NOT FALSE
      UNION ALL
      SELECT p.id, p.name, p.track_inventory, p.item_type, 1 FROM pricebook_items p WHERE lower(btrim(p.name)) = k.lc AND p.active IS NOT FALSE) x
    ORDER BY x.pri, x.track_inventory DESC, (x.item_type = 'material') DESC, x.id LIMIT 1) m ON true
$$;
REVOKE EXECUTE ON FUNCTION public.stock_match_items(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.stock_match_items(text[]) TO authenticated;

-- (2) older POs were stamped with the day they were copied over; put back the day they were ordered
UPDATE public.purchase_orders SET created_at = ordered_at
 WHERE st_id IS NOT NULL AND ordered_at IS NOT NULL AND ordered_at < created_at - interval '1 day';

-- 99zm: equipment details (Section 3: missing details and yearly parts) never go on a sales job or its estimate.
-- Safe to run more than once.
CREATE OR REPLACE FUNCTION public._attach_requests(p_job_id bigint)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r tech_requests; v_loc bigint; n int := 0;
BEGIN
  -- sales jobs (walk sites, estimates) never get the equipment requests
  IF EXISTS (SELECT 1 FROM jobs j JOIN job_types t ON t.id = j.job_type_id WHERE j.id = p_job_id AND t.job_class = 'sales') THEN RETURN 0; END IF;
  SELECT location_id INTO v_loc FROM jobs WHERE id = p_job_id;
  FOR r IN SELECT * FROM tech_requests WHERE location_id = v_loc AND status = 'open' ORDER BY id LOOP
    UPDATE tech_requests SET status = 'added', job_id = p_job_id, added_at = now(),
           note_id = public._job_note(p_job_id, r.body, 'tech_request')
    WHERE id = r.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $function$;

CREATE OR REPLACE FUNCTION public._next_visit(p_location_id bigint, p_maintenance_only boolean)
 RETURNS TABLE(job_id bigint, scheduled_date date, job_number text, job_type text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT j.id, v.scheduled_date, j.job_number, t.name
  FROM visits v JOIN jobs j ON j.id = v.job_id JOIN job_types t ON t.id = j.job_type_id
  WHERE j.location_id = p_location_id
    AND v.status IN ('unscheduled', 'scheduled', 'dispatched')
    AND j.status NOT IN ('completed', 'cancelled')
    AND (v.scheduled_date IS NULL OR v.scheduled_date >= current_date)
    AND (NOT p_maintenance_only OR t.job_class = 'maintenance')
    AND t.job_class <> 'sales'                       -- never a sales visit
  ORDER BY v.scheduled_date NULLS LAST, v.id
  LIMIT 1
$function$;

-- any that already went onto a sales job go back to waiting for a real visit
UPDATE public.tech_requests r SET status = 'open', job_id = NULL, added_at = NULL, note_id = NULL
  FROM public.jobs j JOIN public.job_types t ON t.id = j.job_type_id
 WHERE r.job_id = j.id AND t.job_class = 'sales' AND r.status = 'added';
DELETE FROM public.notes n USING public.jobs j, public.job_types t
 WHERE n.entity_type = 'job' AND n.entity_id = j.id AND t.id = j.job_type_id AND t.job_class = 'sales' AND n.source IN ('tech_request', 'yearly_parts');

-- 99zn: the sales people list also says which staff record each one is, so a sales call can be put on them. Safe to run more than once.
CREATE OR REPLACE FUNCTION public.sales_people() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH me AS (SELECT public.current_app_user_id() AS uid, public._sales_boss() AS boss)
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'emp', u.employee_id, 'name', coalesce(public._emp_name(u.employee_id), u.login_email::text), 'me', u.id = me.uid,
           'can_see', (SELECT coalesce(jsonb_agg(v.seller_user_id), '[]'::jsonb) FROM sales_viewers v WHERE v.viewer_user_id = u.id))
         ORDER BY u.id <> me.uid, coalesce(public._emp_name(u.employee_id), u.login_email::text)), '[]'::jsonb)
  FROM app_users u, me
  WHERE u.role = 'sales' AND u.active AND public.current_staff_role() IS NOT NULL
    AND (me.boss OR u.id = me.uid OR EXISTS (SELECT 1 FROM sales_viewers v WHERE v.viewer_user_id = me.uid AND v.seller_user_id = u.id)) $$;

REVOKE EXECUTE ON FUNCTION public.sales_people() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_people() TO authenticated;

-- 99zo: a sales call is a Site visit or a Phone booking. A site visit waits until the sales person says they're on site.
-- Safe to run more than once.
ALTER TABLE public.jobs ADD COLUMN IF NOT EXISTS sales_kind text;
ALTER TABLE public.jobs ADD COLUMN IF NOT EXISTS sales_on_site_at timestamptz;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'jobs_sales_kind_check') THEN
    ALTER TABLE public.jobs ADD CONSTRAINT jobs_sales_kind_check CHECK (sales_kind IS NULL OR sales_kind IN ('site', 'phone'));
  END IF;
END $$;

-- site visit or phone booking
CREATE OR REPLACE FUNCTION public.set_sales_kind(p_job bigint, p_kind text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  IF p_kind NOT IN ('site', 'phone') THEN RAISE EXCEPTION 'A sales call is a site visit or a phone booking'; END IF;
  UPDATE jobs SET sales_kind = p_kind WHERE id = p_job;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('jobs', p_job, 'update', public.current_app_user_id(), jsonb_build_object('sales_kind', p_kind));
END $$;

-- the sales person is at the customer's
CREATE OR REPLACE FUNCTION public.sales_on_site(p_job bigint) RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE t timestamptz;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  UPDATE jobs SET sales_on_site_at = coalesce(sales_on_site_at, now()), status = CASE WHEN status IN ('new', 'scheduled') THEN 'in_progress' ELSE status END
   WHERE id = p_job RETURNING sales_on_site_at INTO t;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('jobs', p_job, 'update', public.current_app_user_id(), jsonb_build_object('on_site', t));
  RETURN t;
END $$;
REVOKE EXECUTE ON FUNCTION public.set_sales_kind(bigint, text), public.sales_on_site(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_sales_kind(bigint, text), public.sales_on_site(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.sales_list(p_seller bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH me AS (SELECT public._my_employee() AS emp, public.current_app_user_id() AS uid, public._sales_boss() AS boss),
  who AS (   -- whose jobs: one sales person (p_seller), or everyone (owners/dispatchers with no p_seller)
    SELECT CASE WHEN p_seller IS NULL AND me.boss THEN NULL ELSE coalesce(p_seller, me.uid) END AS seller FROM me),
  ok AS (SELECT (me.boss OR who.seller = me.uid OR EXISTS (SELECT 1 FROM sales_viewers v WHERE v.viewer_user_id = me.uid AND v.seller_user_id = who.seller)) AS ok FROM me, who),
  tgt AS (SELECT u.id AS uid, u.employee_id AS emp FROM app_users u, who WHERE u.id = who.seller),
  sp AS (SELECT id AS uid, employee_id AS emp FROM app_users WHERE role = 'sales'),          -- the sales people
  j AS (
    SELECT jb.* FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id, me
    WHERE t.job_class = 'sales' AND public._is_install_sale(t.name) AND jb.created_at > now() - interval '18 months'
      AND (SELECT ok FROM ok)
      AND NOT EXISTS (SELECT 1 FROM estimates ec WHERE ec.job_id = jb.id AND ec.cancelled_at IS NOT NULL)   -- cancelled estimates leave the Sales page
      AND CASE WHEN (SELECT seller FROM who) IS NULL
               -- everyone: jobs of the sales people, and sales jobs booked in this app by the office (not old ServiceTitan ones)
               THEN jb.sales_user_id IS NOT NULL
                    OR EXISTS (SELECT 1 FROM sp WHERE sp.uid = jb.booked_by_user_id OR sp.emp = jb.sold_by_employee_id
                              OR sp.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))
                    OR EXISTS (SELECT 1 FROM app_users u WHERE u.id = jb.booked_by_user_id AND u.role <> 'technician')
               ELSE EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = jb.sales_user_id OR (jb.sales_user_id IS NULL AND (tgt.uid = jb.booked_by_user_id OR tgt.emp = jb.sold_by_employee_id))
                              OR (jb.sales_user_id IS NULL AND tgt.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))) END
    ORDER BY jb.created_at DESC LIMIT 400),
  rows AS (
    SELECT jsonb_build_object(
      'job_id', j.id, 'job_number', j.job_number, 'status', j.status, 'summary', j.summary, 'type', t.name, 'kind', j.sales_kind, 'on_site', j.sales_on_site_at,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = j.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', (SELECT public._emp_name(va.employee_id) FROM visit_assignments va WHERE va.visit_id = v.id ORDER BY va.role = 'lead' DESC LIMIT 1),
      'sales_person', (SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = coalesce(j.sales_user_id, CASE WHEN EXISTS (SELECT 1 FROM app_users b WHERE b.id = j.booked_by_user_id AND b.role = 'sales') THEN j.booked_by_user_id END)),
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

REVOKE EXECUTE ON FUNCTION public.sales_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_list(bigint) TO authenticated;

-- 99zp: which "Sales call for" choices each sales person may use (Reid = 0, or a partner). Not set = all of them.
-- Safe to run more than once.
ALTER TABLE public.app_users ADD COLUMN IF NOT EXISTS sales_for bigint[];

CREATE OR REPLACE FUNCTION public.set_sales_for(p_user bigint, p_ids bigint[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (coalesce(public.current_staff_role() = 'owner', false) OR public.has_permission('staff.manage')) THEN
    RAISE EXCEPTION 'Only an owner can change who a sales person can book for'; END IF;
  UPDATE app_users SET sales_for = p_ids WHERE id = p_user;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('app_users', p_user, 'update', public.current_app_user_id(), jsonb_build_object('sales_for', to_jsonb(p_ids)));
END $$;
REVOKE EXECUTE ON FUNCTION public.set_sales_for(bigint, bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_sales_for(bigint, bigint[]) TO authenticated;

-- a sales person can only make a sales call for a partner they're allowed
CREATE OR REPLACE FUNCTION public.set_job_partner(p_job bigint, p_partner bigint)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE allowed bigint[];
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  IF public.current_staff_role() = 'sales' THEN
    SELECT sales_for INTO allowed FROM app_users WHERE id = public.current_app_user_id();
    IF allowed IS NOT NULL AND NOT (coalesce(p_partner, 0) = ANY (allowed)) THEN RAISE EXCEPTION 'You can''t book sales calls for that partner'; END IF;
  END IF;
  UPDATE jobs SET partner_id = p_partner WHERE id = p_job;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('jobs', p_job, 'update', public.current_app_user_id(), jsonb_build_object('partner_id', p_partner));
END $function$;

CREATE OR REPLACE FUNCTION public.sales_people() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH me AS (SELECT public.current_app_user_id() AS uid, public._sales_boss() AS boss)
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'emp', u.employee_id, 'sales_for', to_jsonb(u.sales_for), 'name', coalesce(public._emp_name(u.employee_id), u.login_email::text), 'me', u.id = me.uid,
           'can_see', (SELECT coalesce(jsonb_agg(v.seller_user_id), '[]'::jsonb) FROM sales_viewers v WHERE v.viewer_user_id = u.id))
         ORDER BY u.id <> me.uid, coalesce(public._emp_name(u.employee_id), u.login_email::text)), '[]'::jsonb)
  FROM app_users u, me
  WHERE u.role = 'sales' AND u.active AND public.current_staff_role() IS NOT NULL
    AND (me.boss OR u.id = me.uid OR EXISTS (SELECT 1 FROM sales_viewers v WHERE v.viewer_user_id = me.uid AND v.seller_user_id = u.id)) $$;

REVOKE EXECUTE ON FUNCTION public.sales_people() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_people() TO authenticated;

-- 99zq: the Sales Dispatch Board. A sales person can only change their own calls on it (move, status, techs),
-- and can't change board notes. Everyone else is unchanged. Safe to run more than once.
CREATE OR REPLACE FUNCTION public._sales_own_visit(p_visit bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(public.current_staff_role(), '') <> 'sales'
      OR EXISTS (SELECT 1 FROM visits v JOIN jobs j ON j.id = v.job_id
                 WHERE v.id = p_visit
                   AND (j.booked_by_user_id = public.current_app_user_id() OR j.sales_user_id = public.current_app_user_id()
                        OR EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id = v.id AND va.employee_id = public._my_employee())))
$$;
REVOKE ALL ON FUNCTION public._sales_own_visit(bigint) FROM public, anon;
GRANT EXECUTE ON FUNCTION public._sales_own_visit(bigint) TO authenticated;

-- add the check to the start of each board action, leaving the rest of each one exactly as it is
DO $$ DECLARE f text; g text; d text; BEGIN
  FOR f, g IN VALUES
    ('move_call(bigint,date,text,text,text)', 'IF NOT public._sales_own_visit(p_visit_id) THEN RAISE EXCEPTION ''You can only change your own calls''; END IF;'),
    ('set_call_status(bigint,text,text)',     'IF NOT public._sales_own_visit(p_visit_id) THEN RAISE EXCEPTION ''You can only change your own calls''; END IF;'),
    ('set_call_techs(bigint,bigint[])',        'IF NOT public._sales_own_visit(p_visit_id) THEN RAISE EXCEPTION ''You can only change your own calls''; END IF;'),
    ('save_board_note(bigint,jsonb)',          'IF public.current_staff_role() = ''sales'' THEN RAISE EXCEPTION ''Sales people can''''t change notes on the board''; END IF;'),
    ('delete_board_note(bigint,date)',         'IF public.current_staff_role() = ''sales'' THEN RAISE EXCEPTION ''Sales people can''''t change notes on the board''; END IF;')
  LOOP
    IF to_regprocedure('public.' || f) IS NULL THEN CONTINUE; END IF;
    d := pg_get_functiondef(to_regprocedure('public.' || f));
    IF position('-- sales-guard' IN d) > 0 THEN CONTINUE; END IF;
    d := regexp_replace(d, E'\nBEGIN\n', E'\nBEGIN\n  ' || g || E'   -- sales-guard\n');
    EXECUTE d;
  END LOOP;
END $$;

-- 99zr: cancel a sales job from the Sales page (with or without an estimate yet). It leaves the Sales page.
-- Safe to run more than once.
ALTER TABLE public.jobs ADD COLUMN IF NOT EXISTS sales_cancelled_at timestamptz;

CREATE OR REPLACE FUNCTION public.sales_job_cancel(p_job bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE j jobs;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Please sign in again'; END IF;
  SELECT * INTO j FROM jobs WHERE id = p_job; IF j.id IS NULL THEN RAISE EXCEPTION 'That job no longer exists'; END IF;
  IF public.current_staff_role() = 'sales' AND NOT (j.booked_by_user_id = public.current_app_user_id() OR j.sales_user_id = public.current_app_user_id()
       OR EXISTS (SELECT 1 FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = j.id AND va.employee_id = public._my_employee())) THEN
    RAISE EXCEPTION 'You can only cancel your own sales jobs'; END IF;
  IF EXISTS (SELECT 1 FROM estimates WHERE job_id = p_job AND status = 'accepted') THEN RAISE EXCEPTION 'This deal is already closed, so it can''t be cancelled'; END IF;
  UPDATE estimates SET cancelled_at = now(), cancelled_by_user_id = public.current_app_user_id(),
         status = CASE WHEN status IN ('draft', 'sent', 'viewed') THEN 'declined' ELSE status END, lost_note = coalesce(lost_note, 'Cancelled'), updated_at = now()
   WHERE job_id = p_job AND cancelled_at IS NULL;
  UPDATE jobs SET sales_cancelled_at = now() WHERE id = p_job;
  IF j.status NOT IN ('completed', 'cancelled') AND NOT EXISTS (SELECT 1 FROM invoices WHERE job_id = p_job) THEN
    UPDATE jobs SET status = 'cancelled' WHERE id = p_job;
    UPDATE visits SET status = 'cancelled' WHERE job_id = p_job AND status IN ('unscheduled', 'scheduled', 'dispatched');
    INSERT INTO job_status_history (job_id, from_status, to_status, changed_by_user_id, note) VALUES (p_job, j.status, 'cancelled', public.current_app_user_id(), 'Sales job cancelled');
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('jobs', p_job, 'update', public.current_app_user_id(), jsonb_build_object('sales_cancelled', true));
END $$;
REVOKE EXECUTE ON FUNCTION public.sales_job_cancel(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_job_cancel(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.sales_list(p_seller bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' SET jit TO 'off'
AS $function$
  WITH me AS (SELECT public._my_employee() AS emp, public.current_app_user_id() AS uid, public._sales_boss() AS boss),
  who AS (   -- whose jobs: one sales person (p_seller), or everyone (owners/dispatchers with no p_seller)
    SELECT CASE WHEN p_seller IS NULL AND me.boss THEN NULL ELSE coalesce(p_seller, me.uid) END AS seller FROM me),
  ok AS (SELECT (me.boss OR who.seller = me.uid OR EXISTS (SELECT 1 FROM sales_viewers v WHERE v.viewer_user_id = me.uid AND v.seller_user_id = who.seller)) AS ok FROM me, who),
  tgt AS (SELECT u.id AS uid, u.employee_id AS emp FROM app_users u, who WHERE u.id = who.seller),
  sp AS (SELECT id AS uid, employee_id AS emp FROM app_users WHERE role = 'sales'),          -- the sales people
  j AS (
    SELECT jb.* FROM jobs jb JOIN job_types t ON t.id = jb.job_type_id, me
    WHERE t.job_class = 'sales' AND public._is_install_sale(t.name) AND jb.created_at > now() - interval '18 months'
      AND (SELECT ok FROM ok)
      AND NOT EXISTS (SELECT 1 FROM estimates ec WHERE ec.job_id = jb.id AND ec.cancelled_at IS NOT NULL)
      AND jb.sales_cancelled_at IS NULL   -- cancelled from the Sales page   -- cancelled estimates leave the Sales page
      AND CASE WHEN (SELECT seller FROM who) IS NULL
               -- everyone: jobs of the sales people, and sales jobs booked in this app by the office (not old ServiceTitan ones)
               THEN jb.sales_user_id IS NOT NULL
                    OR EXISTS (SELECT 1 FROM sp WHERE sp.uid = jb.booked_by_user_id OR sp.emp = jb.sold_by_employee_id
                              OR sp.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))
                    OR EXISTS (SELECT 1 FROM app_users u WHERE u.id = jb.booked_by_user_id AND u.role <> 'technician')
               ELSE EXISTS (SELECT 1 FROM tgt WHERE tgt.uid = jb.sales_user_id OR (jb.sales_user_id IS NULL AND (tgt.uid = jb.booked_by_user_id OR tgt.emp = jb.sold_by_employee_id))
                              OR (jb.sales_user_id IS NULL AND tgt.emp IN (SELECT va.employee_id FROM visits v JOIN visit_assignments va ON va.visit_id = v.id WHERE v.job_id = jb.id))) END
    ORDER BY jb.created_at DESC LIMIT 400),
  rows AS (
    SELECT jsonb_build_object(
      'job_id', j.id, 'job_number', j.job_number, 'status', j.status, 'summary', j.summary, 'type', t.name, 'kind', j.sales_kind, 'on_site', j.sales_on_site_at,
      'customer_id', c.id, 'customer', c.display_name, 'street', l.street, 'city', l.city,
      'partner', (SELECT name FROM partners WHERE id = j.partner_id),
      'visit_date', v.scheduled_date, 'visit_from', v.arrival_start, 'visit_to', v.arrival_end,
      'seller', (SELECT public._emp_name(va.employee_id) FROM visit_assignments va WHERE va.visit_id = v.id ORDER BY va.role = 'lead' DESC LIMIT 1),
      'sales_person', (SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = coalesce(j.sales_user_id, CASE WHEN EXISTS (SELECT 1 FROM app_users b WHERE b.id = j.booked_by_user_id AND b.role = 'sales') THEN j.booked_by_user_id END)),
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

REVOKE EXECUTE ON FUNCTION public.sales_list(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_list(bigint) TO authenticated;

-- 99zs: the price book descriptions of the items on an estimate (shown under each line). Safe to run more than once.
DROP FUNCTION IF EXISTS public.est_item_info(bigint[]);
CREATE FUNCTION public.est_item_info(p_ids bigint[]) RETURNS TABLE(id bigint, description text, has_picture boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT i.id, i.description, EXISTS (SELECT 1 FROM pricebook_pictures p WHERE p.item_id = i.id)
  FROM pricebook_items i
  WHERE public.current_staff_role() IS NOT NULL AND i.id = ANY (p_ids[1:300])
$$;
REVOKE EXECUTE ON FUNCTION public.est_item_info(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_item_info(bigint[]) TO authenticated;

-- 99zt: costing for an estimate (owners and anyone who can see costs): each item's cost and labour hours,
-- and the materials its kit adds. Safe to run more than once.
CREATE OR REPLACE FUNCTION public.est_costing(p_ids bigint[]) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL OR NOT public._can_see_costs() THEN '[]'::jsonb ELSE coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'cost', i.unit_cost, 'hours', i.est_labour_hours, 'price', i.unit_price,
           'parts', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'sku', p.sku, 'qty', kp.quantity, 'cost', p.unit_cost, 'hours', p.est_labour_hours) ORDER BY kp.seq), '[]'::jsonb)
                     FROM public.pb_kit_parts(i.id) kp JOIN pricebook_items p ON p.id = kp.item_id))), '[]'::jsonb) END
  FROM pricebook_items i WHERE i.id = ANY (p_ids[1:300])
$$;
REVOKE EXECUTE ON FUNCTION public.est_costing(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_costing(bigint[]) TO authenticated;

-- 99zu: on an estimate, materials from an item's kit can be taken off that line (owners). Safe to run more than once.
ALTER TABLE public.estimate_lines ADD COLUMN IF NOT EXISTS kit_skip bigint[];

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
      INSERT INTO estimate_lines (estimate_option_id, sequence, item_id, description, quantity, unit_price, unit_cost, est_labour_hours, taxable, kit_skip)
      SELECT v_opt, k, i.id, coalesce(nullif(btrim(ln ->> 'description'), ''), i.name, 'Item'), coalesce((ln ->> 'qty')::numeric, 1),
             coalesce((ln ->> 'price')::numeric, i.unit_price, 0), coalesce(i.unit_cost, 0), i.est_labour_hours, coalesce(i.taxable, true),
             CASE WHEN jsonb_typeof(ln -> 'skip') = 'array' AND jsonb_array_length(ln -> 'skip') > 0
                  THEN ARRAY(SELECT x::bigint FROM jsonb_array_elements_text(ln -> 'skip') x WHERE x ~ '^[0-9]+$') END
      FROM (SELECT 1) one LEFT JOIN pricebook_items i ON i.id = nullif(ln ->> 'item_id', '')::bigint;
    END LOOP;
  END LOOP;
  UPDATE estimates SET status = CASE WHEN p ? 'sent' AND (p ->> 'sent')::boolean THEN 'sent' ELSE status END,
         sent_at = CASE WHEN p ? 'sent' AND (p ->> 'sent')::boolean AND sent_at IS NULL THEN now() ELSE sent_at END, updated_at = now() WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('estimates', p_id, 'update', public.current_app_user_id(), jsonb_build_object('options', n));
END $$;

REVOKE EXECUTE ON FUNCTION public.est_save(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_save(bigint, jsonb) TO authenticated;

-- 99zv: estimates like the ServiceTitan proposal: part codes and maker on each line, tagline, REG number,
-- financing estimate, and the customer authorization wording. Safe to run more than once.
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS tagline text;
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS reg_number text;
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS finance_apr numeric;
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS finance_months integer;
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS estimate_terms text;
-- fill only what's empty, from the ServiceTitan proposal
UPDATE public.company_settings SET
  street = coalesce(nullif(btrim(street), ''), '36 Capital Dr.'), city = coalesce(nullif(btrim(city), ''), 'Nepean'),
  province = coalesce(nullif(btrim(province), ''), 'ON'), postal_code = coalesce(nullif(btrim(postal_code), ''), 'K2G 0E9'),
  phone = coalesce(nullif(btrim(phone), ''), '6132331115'),
  tagline = coalesce(tagline, 'SERVICE, You Can Trust !'), reg_number = coalesce(reg_number, '855889721'),
  finance_apr = coalesce(finance_apr, 10.5), finance_months = coalesce(finance_months, 120),
  estimate_terms = coalesce(estimate_terms, 'THIS IS AN ESTIMATE, NOT A CONTRACT FOR SERVICES. The summary above is furnished by Reid Heating and Cooling, A Division of Home Service Group Inc. as a good faith estimate of work to be performed at the location described above and is based on our evaluation and does not include material price increases or additional labor and materials which may be required should unforeseen problems arise after the work has started. I understand that the final cost of the work may differ from the estimate, perhaps materially. THIS IS NOT A GUARANTEE OF THE FINAL PRICE OF WORK TO BE PERFORMED. I agree and authorize the work as summarized on these estimated terms, and I agree to pay the full amount for all work performed.');

-- each item's part code and maker too
DROP FUNCTION IF EXISTS public.est_item_info(bigint[]);
CREATE FUNCTION public.est_item_info(p_ids bigint[]) RETURNS TABLE(id bigint, description text, has_picture boolean, sku text, manufacturer text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT i.id, i.description, EXISTS (SELECT 1 FROM pricebook_pictures p WHERE p.item_id = i.id), i.sku, i.manufacturer
  FROM pricebook_items i
  WHERE public.current_staff_role() IS NOT NULL AND i.id = ANY (p_ids[1:300])
$$;
REVOKE EXECUTE ON FUNCTION public.est_item_info(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.est_item_info(bigint[]) TO authenticated;

-- =====================================================================
-- Add-on kits page: duplicate a kit's parts list under a new name, and rename a kit.
-- The copy gets the same parts and quantities but is not connected to any equipment
-- (so an install never posts both kits). Safe to run more than once.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.copy_addon_kit(p_kit bigint, p_name text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id bigint;
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF NOT public._is_addon_kit(p_kit) THEN RAISE EXCEPTION 'That is not an add-on kit'; END IF;
  v_id := public.new_addon_kit(p_name);
  INSERT INTO pricebook_kit_items (parent_item_id, component_item_id, quantity, is_optional, sequence)
  SELECT v_id, k.component_item_id, k.quantity, k.is_optional, k.sequence
  FROM pricebook_kit_items k WHERE k.parent_item_id = p_kit
  ON CONFLICT DO NOTHING;
  UPDATE pricebook_items n SET description = o.description
  FROM pricebook_items o WHERE n.id = v_id AND o.id = p_kit AND coalesce(o.description, '') <> '' AND o.description <> o.name;
  PERFORM public.pb_kit_cost_refresh(v_id);
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pricebook_items', v_id, 'update', public.current_app_user_id(), jsonb_build_object('change', 'copied from kit ' || p_kit));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.rename_addon_kit(p_kit bigint, p_name text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_name text := btrim(p_name); v_old text;
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF NOT public._is_addon_kit(p_kit) THEN RAISE EXCEPTION 'That is not an add-on kit'; END IF;
  IF coalesce(v_name, '') = '' THEN RAISE EXCEPTION 'Give the kit a name'; END IF;
  IF v_name !~* 'kit' THEN v_name := v_name || ' Add-on Kit'; END IF;
  SELECT name INTO v_old FROM pricebook_items WHERE id = p_kit;
  UPDATE pricebook_items SET name = v_name,
         description = CASE WHEN description IS NULL OR description = v_old THEN v_name ELSE description END,
         updated_at = now()
  WHERE id = p_kit;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('pricebook_items', p_kit, 'update', public.current_app_user_id(), jsonb_build_object('name', v_old), jsonb_build_object('name', v_name, 'change', 'renamed add-on kit'));
END $$;

REVOKE EXECUTE ON FUNCTION public.copy_addon_kit(bigint, text), public.rename_addon_kit(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.copy_addon_kit(bigint, text), public.rename_addon_kit(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';


-- =====================================================================
-- Add-on kits: labour on the kit (hours to install × techs needed × cost per hour),
-- delete a kit, and the sales person's name for "Provided to you by" on estimates.
-- Equipment connected to a kit takes the kit's labour (unless the item has its own override),
-- on the item's Labour cost box and in the estimate costing. Safe to run more than once.
-- =====================================================================

-- the labour an item uses: its own override, else the labour of a kit it's connected to
CREATE OR REPLACE FUNCTION public._item_labour(p_item bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(
    (SELECT jsonb_build_object('hours', i.labour_hours, 'techs', coalesce(i.labour_techs, 1),
              'rate', coalesce(i.labour_rate, (SELECT labour_cost_per_hour FROM company_settings ORDER BY id LIMIT 1)), 'from', 'own')
     FROM pricebook_items i WHERE i.id = p_item AND i.labour_hours IS NOT NULL),
    (SELECT jsonb_build_object('hours', kt.labour_hours, 'techs', coalesce(kt.labour_techs, 1),
              'rate', coalesce(kt.labour_rate, (SELECT labour_cost_per_hour FROM company_settings ORDER BY id LIMIT 1)), 'from', 'kit', 'kit', kt.name)
     FROM pricebook_kit_items k JOIN pricebook_items kt ON kt.id = k.component_item_id
     WHERE k.parent_item_id = p_item AND kt.labour_hours IS NOT NULL
     ORDER BY k.sequence, k.id LIMIT 1))
$$;

-- All the add-on kits, now with their labour
DROP FUNCTION IF EXISTS public.pb_addon_kits();
CREATE FUNCTION public.pb_addon_kits()
RETURNS TABLE (id bigint, sku text, name text, description text, active boolean, parts int, parts_cost numeric, equipment int, updated_at timestamptz,
               labour_hours numeric, labour_techs int, labour_rate numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, p.sku, p.name, p.description, p.active,
         (SELECT count(*)::int FROM public.pb_kit_parts(p.id)),
         CASE WHEN public._can_see_costs() THEN (SELECT round(sum(kp.quantity * c.unit_cost), 2) FROM public.pb_kit_parts(p.id) kp JOIN pricebook_items c ON c.id = kp.item_id) END,
         (SELECT count(*)::int FROM pricebook_kit_items k WHERE k.component_item_id = p.id),
         p.updated_at, p.labour_hours, p.labour_techs,
         CASE WHEN public._can_see_costs() THEN p.labour_rate END
  FROM pricebook_items p
  WHERE public.current_staff_role() IS NOT NULL AND public._is_addon_kit(p.id)
  ORDER BY p.active DESC, p.name
$$;

-- An item's labour box: a kit with its own labour gives hours, techs and rate
CREATE OR REPLACE FUNCTION public.pb_item_labour(p_item bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public SET jit = off AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE jsonb_build_object(
    'own', (SELECT CASE WHEN i.labour_hours IS NULL AND i.labour_rate IS NULL THEN NULL ELSE jsonb_build_object(
              'hours', i.labour_hours, 'techs', i.labour_techs, 'rate', i.labour_rate, 'at', i.labour_set_at,
              'by', (SELECT coalesce(public._emp_name(u.employee_id), u.login_email::text) FROM app_users u WHERE u.id = i.labour_set_by)) END
            FROM pricebook_items i WHERE i.id = p_item),
    'kit', coalesce(
            (SELECT jsonb_build_object('hours', kt.labour_hours, 'techs', coalesce(kt.labour_techs, 1), 'rate', kt.labour_rate, 'names', jsonb_build_array(kt.name), 'kitlab', true)
             FROM pricebook_kit_items k JOIN pricebook_items kt ON kt.id = k.component_item_id
             WHERE k.parent_item_id = p_item AND kt.labour_hours IS NOT NULL ORDER BY k.sequence, k.id LIMIT 1),
            (SELECT CASE WHEN count(*) = 0 THEN NULL ELSE jsonb_build_object(
              'hours', round(sum(k.quantity * coalesce(c.est_labour_hours, 0)), 2),
              'names', (SELECT jsonb_agg(c2.name ORDER BY x.sequence) FROM pricebook_kit_items x JOIN pricebook_items c2 ON c2.id = x.component_item_id WHERE x.parent_item_id = p_item)) END
             FROM public.pb_kit_parts(p_item) k JOIN pricebook_items c ON c.id = k.item_id)),
    'rate', (SELECT labour_cost_per_hour FROM company_settings ORDER BY id LIMIT 1)) END
$$;

-- Estimate costing: each item also says which labour it uses (hours × techs × rate)
CREATE OR REPLACE FUNCTION public.est_costing(p_ids bigint[])
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL OR NOT public._can_see_costs() THEN '[]'::jsonb ELSE coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'cost', i.unit_cost, 'hours', i.est_labour_hours, 'price', i.unit_price, 'lab', public._item_labour(i.id),
           'parts', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'sku', p.sku, 'qty', kp.quantity, 'cost', p.unit_cost, 'hours', p.est_labour_hours) ORDER BY kp.seq), '[]'::jsonb)
                     FROM public.pb_kit_parts(i.id) kp JOIN pricebook_items p ON p.id = kp.item_id))), '[]'::jsonb) END
  FROM pricebook_items i WHERE i.id = ANY (p_ids[1:300])
$$;

-- Delete an add-on kit: takes it off all equipment and empties it; removed for good if nothing used it, else retired
CREATE OR REPLACE FUNCTION public.delete_addon_kit(p_kit bigint)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_name text;
BEGIN
  IF NOT public.has_permission('pricebook.edit') THEN RAISE EXCEPTION 'You don''t have permission to change the price book'; END IF;
  IF NOT public._is_addon_kit(p_kit) THEN RAISE EXCEPTION 'That is not an add-on kit'; END IF;
  SELECT name INTO v_name FROM pricebook_items WHERE id = p_kit;
  DELETE FROM pricebook_kit_items WHERE parent_item_id = p_kit OR component_item_id = p_kit;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('pricebook_items', p_kit, 'delete', public.current_app_user_id(), jsonb_build_object('name', v_name), jsonb_build_object('change', 'deleted add-on kit'));
  BEGIN
    DELETE FROM pricebook_items WHERE id = p_kit;
    RETURN 'deleted';
  EXCEPTION WHEN foreign_key_violation THEN
    -- used on an old invoice or estimate: keep the row for those, but it's no longer a kit
    UPDATE pricebook_items SET active = false, sku = 'X' || sku, updated_at = now() WHERE id = p_kit;
    RETURN 'retired';
  END;
END $$;

-- The sales person on an estimate: the job's sales person, else who made it
CREATE OR REPLACE FUNCTION public.est_seller(p_id bigint)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE coalesce(
    (SELECT nullif(btrim(coalesce(em.first_name, '') || ' ' || coalesce(em.last_name, '')), '')
     FROM estimates e JOIN jobs j ON j.id = e.job_id JOIN app_users u ON u.id = j.sales_user_id JOIN employees em ON em.id = u.employee_id WHERE e.id = p_id),
    (SELECT nullif(btrim(coalesce(em.first_name, '') || ' ' || coalesce(em.last_name, '')), '')
     FROM estimates e JOIN employees em ON em.id = e.sold_by_employee_id WHERE e.id = p_id)) END
$$;

REVOKE EXECUTE ON FUNCTION public._item_labour(bigint), public.pb_addon_kits(), public.delete_addon_kit(bigint), public.est_seller(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._item_labour(bigint), public.pb_addon_kits(), public.delete_addon_kit(bigint), public.est_seller(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';


-- =====================================================================
-- Estimate costing matches the Pricing formulas page: an item priced by a formula also carries
-- the formula's thermostat/coil, material, warranty, labour and office amounts.
-- (The estimate uses the real kit parts for material and the kit's labour when those are set.)
-- Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.est_costing(p_ids bigint[])
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL OR NOT public._can_see_costs() THEN '[]'::jsonb ELSE coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'cost', i.unit_cost, 'hours', i.est_labour_hours, 'price', i.unit_price, 'lab', public._item_labour(i.id),
           'formula', (SELECT jsonb_build_object('name', f.name, 'material', f.material, 'warranty', f.warranty, 'labour', f.labour, 'office', f.office,
                         'addon', coalesce((SELECT a.unit_cost FROM pricebook_items a WHERE a.id = coalesce(i.formula_addon_item_id, f.addon_item_id)), 0),
                         'addon_name', (SELECT a.name FROM pricebook_items a WHERE a.id = coalesce(i.formula_addon_item_id, f.addon_item_id)))
                       FROM price_formulas f WHERE f.id = i.price_formula_id),
           'parts', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'sku', p.sku, 'qty', kp.quantity, 'cost', p.unit_cost, 'hours', p.est_labour_hours) ORDER BY kp.seq), '[]'::jsonb)
                     FROM public.pb_kit_parts(i.id) kp JOIN pricebook_items p ON p.id = kp.item_id))), '[]'::jsonb) END
  FROM pricebook_items i WHERE i.id = ANY (p_ids[1:300])
$$;
NOTIFY pgrst, 'reload schema';


-- =====================================================================
-- Security page (owners only): mark customers as PAP (pre-authorized payment) from an Excel list.
-- Two lists: 'monthly' (monthly billing) and 'other' (every other PAP customer).
-- Only the customer number, name and phone from the file are used; nothing else in the file
-- (like bank details) is read or stored. Safe to run more than once.
-- =====================================================================
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS pap_list text;
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS pap_set_at timestamptz;
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS pap_set_by bigint;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'customers_pap_list_check') THEN
    ALTER TABLE public.customers ADD CONSTRAINT customers_pap_list_check CHECK (pap_list IS NULL OR pap_list IN ('monthly', 'other'));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS customers_pap_idx ON public.customers (pap_list) WHERE pap_list IS NOT NULL;
CREATE INDEX IF NOT EXISTS customers_name_lc_idx ON public.customers (lower(btrim(display_name)));

CREATE OR REPLACE FUNCTION public._is_owner() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$ SELECT public.current_staff_role() = 'owner' $$;

-- Match the rows of the file to customers: by customer number, then phone, then the exact name (only when one customer has it)
-- p_rows: [{"i": row number, "num": "...", "name": "...", "phone": "..."}]
CREATE OR REPLACE FUNCTION public.pap_match(p_rows jsonb)
RETURNS TABLE (i int, customer_id bigint, customer_number text, name text, how text, pap_list text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '60s' AS $$
BEGIN
  IF NOT public._is_owner() THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  RETURN QUERY
  WITH r AS MATERIALIZED (
    SELECT x.i, nullif(regexp_replace(btrim(coalesce(x.num, '')), '\.0+$', ''), '') AS num, nullif(lower(btrim(coalesce(x.name, ''))), '') AS nm,
           nullif(right(regexp_replace(coalesce(x.phone, ''), '\D', '', 'g'), 10), '') AS ph
    FROM jsonb_to_recordset(p_rows) AS x(i int, num text, name text, phone text)),
  byname AS MATERIALIZED (SELECT lower(btrim(c.display_name)) AS nm, min(c.id) AS id, count(*) AS n FROM customers c
             WHERE c.merged_into_id IS NULL AND lower(btrim(c.display_name)) IN (SELECT r.nm FROM r WHERE r.nm IS NOT NULL) GROUP BY 1),
  byphone AS MATERIALIZED (SELECT right(regexp_replace(k.value, '\D', '', 'g'), 10) AS ph, min(k.customer_id) AS id, count(DISTINCT k.customer_id) AS n FROM customer_contacts k
              WHERE k.kind IN ('phone', 'mobile') AND right(regexp_replace(k.value, '\D', '', 'g'), 10) IN (SELECT r.ph FROM r WHERE length(r.ph) = 10) GROUP BY 1),
  m AS MATERIALIZED (
    SELECT r.i, coalesce(cn.id, cs.id) AS by_num, CASE WHEN p.n = 1 THEN p.id END AS by_phone, CASE WHEN b.n = 1 THEN b.id END AS by_name
    FROM r
    LEFT JOIN customers cn ON cn.customer_number = r.num
    LEFT JOIN customers cs ON cs.st_id = CASE WHEN r.num ~ '^[0-9]{1,15}$' THEN r.num::bigint END
    LEFT JOIN byphone p ON p.ph = r.ph
    LEFT JOIN byname b ON b.nm = r.nm)
  SELECT m.i, c.id, c.customer_number, c.display_name,
         CASE WHEN m.by_num IS NOT NULL THEN 'number' WHEN m.by_phone IS NOT NULL THEN 'phone' ELSE 'name' END,
         c.pap_list
  FROM m
  JOIN customers c0 ON c0.id = coalesce(m.by_num, m.by_phone, m.by_name)
  JOIN customers c ON c.id = coalesce(c0.merged_into_id, c0.id);
END $$;

-- Put customers on a list (and, if asked, take everyone else off that list)
CREATE OR REPLACE FUNCTION public.pap_set(p_ids bigint[], p_list text, p_replace boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_on int; v_off int := 0; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT public._is_owner() THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF p_list IS NOT NULL AND p_list NOT IN ('monthly', 'other') THEN RAISE EXCEPTION 'Pick a list'; END IF;
  IF p_list IS NULL THEN   -- take these customers off PAP
    UPDATE customers SET pap_list = NULL, pap_set_at = now(), pap_set_by = v_me WHERE id = ANY (p_ids) AND pap_list IS NOT NULL;
    GET DIAGNOSTICS v_off = ROW_COUNT;
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
    VALUES ('customers', 0, 'update', v_me, jsonb_build_object('change', 'taken off PAP', 'count', v_off));
    RETURN jsonb_build_object('on', 0, 'off', v_off);
  END IF;
  UPDATE customers SET pap_list = p_list, pap_set_at = now(), pap_set_by = v_me
  WHERE id = ANY (p_ids) AND pap_list IS DISTINCT FROM p_list;
  GET DIAGNOSTICS v_on = ROW_COUNT;
  IF p_replace THEN
    UPDATE customers SET pap_list = NULL, pap_set_at = now(), pap_set_by = v_me
    WHERE pap_list = p_list AND NOT (id = ANY (p_ids));
    GET DIAGNOSTICS v_off = ROW_COUNT;
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('customers', 0, 'update', v_me, jsonb_build_object('change', 'PAP list ' || p_list, 'added', v_on, 'removed', v_off));
  RETURN jsonb_build_object('on', v_on, 'off', v_off);
END $$;

-- Who is on the PAP lists
CREATE OR REPLACE FUNCTION public.pap_list_rows()
RETURNS TABLE (id bigint, customer_number text, name text, pap_list text, pap_set_at timestamptz, phone text, address text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT c.id, c.customer_number, c.display_name, c.pap_list, c.pap_set_at,
         (SELECT k.value FROM customer_contacts k WHERE k.customer_id = c.id AND k.kind <> 'email' ORDER BY k.is_primary DESC, k.id LIMIT 1),
         (SELECT concat_ws(', ', l.street, l.city) FROM locations l WHERE l.customer_id = c.id ORDER BY l.active DESC, l.id LIMIT 1)
  FROM customers c
  WHERE public._is_owner() AND c.pap_list IS NOT NULL
  ORDER BY c.display_name
$$;

REVOKE EXECUTE ON FUNCTION public._is_owner(), public.pap_match(jsonb), public.pap_set(bigint[], text, boolean), public.pap_list_rows() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._is_owner(), public.pap_match(jsonb), public.pap_set(bigint[], text, boolean), public.pap_list_rows() TO authenticated;

NOTIFY pgrst, 'reload schema';


-- =====================================================================
-- HTIN List: "Book a job" for a booking with no job yet. After the call is booked, the new job
-- becomes the partner's job (with their booking # as its reference) and the booking is linked to it.
-- Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.htin_book_link(p_booking bigint, p_job bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b partner_bookings;
BEGIN
  IF NOT public.has_permission('calls.book') AND public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'You don''t have permission to book calls'; END IF;
  SELECT * INTO b FROM partner_bookings WHERE id = p_booking;
  IF b.id IS NULL THEN RAISE EXCEPTION 'That booking is not on the list any more'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jobs WHERE id = p_job) THEN RAISE EXCEPTION 'That job is not there'; END IF;
  UPDATE jobs SET partner_id = b.partner_id, partner_reference = coalesce(partner_reference, b.ref), updated_at = now() WHERE id = p_job;
  UPDATE partner_bookings SET job_id = p_job, customer_id = coalesce(customer_id, (SELECT customer_id FROM jobs WHERE id = p_job)), updated_at = now() WHERE id = p_booking;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('partner_bookings', p_booking, 'update', public.current_app_user_id(), jsonb_build_object('change', 'booked job from the list', 'job_id', p_job));
END $$;
REVOKE EXECUTE ON FUNCTION public.htin_book_link(bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.htin_book_link(bigint, bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';


-- =====================================================================
-- HTIN List: edit a booking from its side panel (like the bookings board): status, technician,
-- service date, service, client name / phone / email, address and notes. Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.partner_booking_edit(p_id bigint, p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE old partner_bookings;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  SELECT * INTO old FROM partner_bookings WHERE id = p_id;
  IF old.id IS NULL THEN RAISE EXCEPTION 'That booking is no longer on the list'; END IF;
  IF p ? 'their_name' AND coalesce(btrim(p ->> 'their_name'), '') = '' THEN RAISE EXCEPTION 'Add the client''s name'; END IF;
  UPDATE partner_bookings SET
    status       = CASE WHEN p ? 'status'       THEN nullif(btrim(p ->> 'status'), '')       ELSE status END,
    provider     = CASE WHEN p ? 'provider'     THEN nullif(btrim(p ->> 'provider'), '')     ELSE provider END,
    service_date = CASE WHEN p ? 'service_date' THEN nullif(p ->> 'service_date', '')::timestamptz ELSE service_date END,
    service      = CASE WHEN p ? 'service'      THEN nullif(btrim(p ->> 'service'), '')      ELSE service END,
    their_name   = CASE WHEN p ? 'their_name'   THEN nullif(btrim(p ->> 'their_name'), '')   ELSE their_name END,
    phone        = CASE WHEN p ? 'phone'        THEN nullif(btrim(p ->> 'phone'), '')        ELSE phone END,
    email        = CASE WHEN p ? 'email'        THEN nullif(btrim(p ->> 'email'), '')        ELSE email END,
    address      = CASE WHEN p ? 'address'      THEN nullif(btrim(p ->> 'address'), '')      ELSE address END,
    extra        = CASE WHEN p ? 'extra'        THEN nullif(btrim(p ->> 'extra'), '')        ELSE extra END,
    note         = CASE WHEN p ? 'note'         THEN nullif(btrim(p ->> 'note'), '')         ELSE note END,
    updated_at = now()
  WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('partner_bookings', p_id, 'update', public.current_app_user_id(),
          jsonb_build_object('status', old.status, 'service_date', old.service_date, 'provider', old.provider), p);
END $$;
REVOKE EXECUTE ON FUNCTION public.partner_booking_edit(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.partner_booking_edit(bigint, jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';


-- =====================================================================
-- HTIN List: the full booking record from the bookings board (contract #, rental equipment, issue,
-- costs, products, status history with tech notes and signatures, alerts...) kept with each booking.
-- Loaded from the board file ("Update from the board"), and edited from the booking's side panel.
-- Safe to run more than once.
-- =====================================================================
ALTER TABLE public.partner_bookings ADD COLUMN IF NOT EXISTS details jsonb;

-- one booking's full record, for its side panel
CREATE OR REPLACE FUNCTION public.partner_booking_details(p_id bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE coalesce(details, '{}'::jsonb) END
  FROM partner_bookings WHERE id = p_id
$$;

-- load the board's records: p_rows = [{ref, details}] (the bookings themselves come in first, the same way as their Excel)
CREATE OR REPLACE FUNCTION public.partner_booking_details_import(p_partner bigint, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r jsonb; n int := 0; miss int := 0;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  IF jsonb_array_length(p_rows) > 200 THEN RAISE EXCEPTION 'Up to 200 at a time'; END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    UPDATE partner_bookings SET details = r -> 'details', updated_at = now()
    WHERE partner_id = p_partner AND ref = btrim(r ->> 'ref') AND details IS DISTINCT FROM (r -> 'details');
    IF FOUND THEN n := n + 1;
    ELSIF NOT EXISTS (SELECT 1 FROM partner_bookings WHERE partner_id = p_partner AND ref = btrim(r ->> 'ref')) THEN miss := miss + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('updated', n, 'missing', miss);
END $$;

-- the side panel's Save also keeps the full record
CREATE OR REPLACE FUNCTION public.partner_booking_edit(p_id bigint, p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE old partner_bookings;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  SELECT * INTO old FROM partner_bookings WHERE id = p_id;
  IF old.id IS NULL THEN RAISE EXCEPTION 'That booking is no longer on the list'; END IF;
  IF p ? 'their_name' AND coalesce(btrim(p ->> 'their_name'), '') = '' THEN RAISE EXCEPTION 'Add the client''s name'; END IF;
  UPDATE partner_bookings SET
    status       = CASE WHEN p ? 'status'       THEN nullif(btrim(p ->> 'status'), '')       ELSE status END,
    provider     = CASE WHEN p ? 'provider'     THEN nullif(btrim(p ->> 'provider'), '')     ELSE provider END,
    service_date = CASE WHEN p ? 'service_date' THEN nullif(p ->> 'service_date', '')::timestamptz ELSE service_date END,
    service      = CASE WHEN p ? 'service'      THEN nullif(btrim(p ->> 'service'), '')      ELSE service END,
    their_name   = CASE WHEN p ? 'their_name'   THEN nullif(btrim(p ->> 'their_name'), '')   ELSE their_name END,
    phone        = CASE WHEN p ? 'phone'        THEN nullif(btrim(p ->> 'phone'), '')        ELSE phone END,
    email        = CASE WHEN p ? 'email'        THEN nullif(btrim(p ->> 'email'), '')        ELSE email END,
    address      = CASE WHEN p ? 'address'      THEN nullif(btrim(p ->> 'address'), '')      ELSE address END,
    extra        = CASE WHEN p ? 'extra'        THEN nullif(btrim(p ->> 'extra'), '')        ELSE extra END,
    note         = CASE WHEN p ? 'note'         THEN nullif(btrim(p ->> 'note'), '')         ELSE note END,
    details      = CASE WHEN p ? 'details' AND jsonb_typeof(p -> 'details') = 'object' THEN p -> 'details' ELSE details END,
    updated_at = now()
  WHERE id = p_id;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, old_values, new_values)
  VALUES ('partner_bookings', p_id, 'update', public.current_app_user_id(),
          jsonb_build_object('status', old.status, 'service_date', old.service_date, 'provider', old.provider), p - 'details');
END $$;

REVOKE EXECUTE ON FUNCTION public.partner_booking_details(bigint), public.partner_booking_details_import(bigint, jsonb), public.partner_booking_edit(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.partner_booking_details(bigint), public.partner_booking_details_import(bigint, jsonb), public.partner_booking_edit(bigint, jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';


-- =====================================================================
-- HTIN List: the daily "HSG Bookings" workbook both ways (Bookings, Products, Status History, Alerts).
-- Importing keeps what was added in our app: status updates and alerts that aren't in the file stay,
-- and office notes only fill in when ours are empty. Exporting gives every booking with its full record.
-- Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.partner_booking_details_import(p_partner bigint, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r jsonb; n int := 0; miss int := 0; b partner_bookings; nd jsonb; h jsonb; a jsonb;
BEGIN
  IF public.current_staff_role() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  IF jsonb_array_length(p_rows) > 200 THEN RAISE EXCEPTION 'Up to 200 at a time'; END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    SELECT * INTO b FROM partner_bookings WHERE partner_id = p_partner AND ref = btrim(r ->> 'ref');
    IF b.id IS NULL THEN miss := miss + 1; CONTINUE; END IF;
    nd := coalesce(r -> 'details', '{}'::jsonb);
    -- status updates added in our app (not in the file) stay, in time order
    h := coalesce(nd -> 'history', '[]'::jsonb) || coalesce((SELECT jsonb_agg(x) FROM jsonb_array_elements(coalesce(b.details -> 'history', '[]'::jsonb)) x
           WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(nd -> 'history', '[]'::jsonb)) y WHERE y ->> 'status' = x ->> 'status' AND left(y ->> 'at', 16) = left(x ->> 'at', 16))), '[]'::jsonb);
    h := coalesce((SELECT jsonb_agg(x ORDER BY x ->> 'at') FROM jsonb_array_elements(h) x), '[]'::jsonb);
    -- alerts added in our app stay too
    a := coalesce(nd -> 'alerts', '[]'::jsonb) || coalesce((SELECT jsonb_agg(x) FROM jsonb_array_elements(coalesce(b.details -> 'alerts', '[]'::jsonb)) x
           WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(nd -> 'alerts', '[]'::jsonb)) y
                             WHERE (y ->> 'id' IS NOT NULL AND y ->> 'id' = x ->> 'id') OR (y ->> 'title' = x ->> 'title' AND left(coalesce(y ->> 'created', ''), 16) = left(coalesce(x ->> 'created', ''), 16)))), '[]'::jsonb);
    nd := nd || jsonb_build_object('history', h, 'alerts', a);
    UPDATE partner_bookings SET details = nd,
           note = CASE WHEN note IS NULL AND nullif(btrim(r ->> 'note'), '') IS NOT NULL THEN btrim(r ->> 'note') ELSE note END, updated_at = now()
    WHERE id = b.id AND (details IS DISTINCT FROM nd OR (note IS NULL AND nullif(btrim(r ->> 'note'), '') IS NOT NULL));
    IF FOUND THEN n := n + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('updated', n, 'missing', miss);
END $$;

-- their file's Created time is the one to keep (it can be re-sent more exactly)
CREATE OR REPLACE FUNCTION public.partner_bookings_import(p_partner bigint, p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r jsonb; m jsonb; v_new int := 0; v_upd int := 0; v_id bigint; v_was boolean;
BEGIN
  IF public.current_staff_role() IS NULL AND current_user NOT IN ('postgres', 'supabase_admin') THEN RAISE EXCEPTION 'Sign in first'; END IF;
  IF jsonb_array_length(p_rows) > 500 THEN RAISE EXCEPTION 'Up to 500 rows at a time'; END IF;
  -- who each one is (same matching as "Add our notes to a file": by address, confirmed by phone, email or name)
  m := public.partner_file_notes(p_partner, (SELECT jsonb_agg(jsonb_build_object('i', o - 1, 'phone', x ->> 'phone', 'email', x ->> 'email', 'address', x ->> 'address',
          'name', x ->> 'name', 'date', left(x ->> 'created', 10))) FROM jsonb_array_elements(p_rows) WITH ORDINALITY t(x, o)), 1, false);
  FOR r IN SELECT x || coalesce((SELECT jsonb_build_object('customer_id', y -> 'customer_id', 'job_id', y -> 'job_id', 'how', y -> 'how', 'addr_ok', y -> 'addr_ok')
                                 FROM jsonb_array_elements(m) y WHERE (y ->> 'i')::int = o - 1), '{}') FROM jsonb_array_elements(p_rows) WITH ORDINALITY t(x, o) LOOP
    v_was := EXISTS (SELECT 1 FROM partner_bookings WHERE partner_id = p_partner AND ref = r ->> 'ref');
    INSERT INTO partner_bookings AS b (partner_id, ref, booked_at, status, service, service_date, their_name, address, extra, email, phone, provider,
                                       customer_id, job_id, match_how, addr_ok, source, added_by)
    VALUES (p_partner, nullif(btrim(r ->> 'ref'), ''), (r ->> 'created')::timestamptz, nullif(btrim(r ->> 'status'), ''), nullif(btrim(r ->> 'service'), ''),
            (r ->> 'service_date')::timestamptz, nullif(btrim(r ->> 'name'), ''), nullif(btrim(r ->> 'address'), ''), nullif(btrim(r ->> 'extra'), ''),
            nullif(btrim(r ->> 'email'), ''), nullif(btrim(r ->> 'phone'), ''), nullif(btrim(r ->> 'provider'), ''),
            (r ->> 'customer_id')::bigint, (r ->> 'job_id')::bigint, r ->> 'how', (r ->> 'addr_ok')::boolean, 'file', public.current_app_user_id())
    ON CONFLICT (partner_id, ref) WHERE ref IS NOT NULL DO UPDATE SET
      status = EXCLUDED.status, booked_at = coalesce(EXCLUDED.booked_at, b.booked_at), service = coalesce(EXCLUDED.service, b.service), service_date = coalesce(EXCLUDED.service_date, b.service_date),
      their_name = coalesce(EXCLUDED.their_name, b.their_name), address = coalesce(EXCLUDED.address, b.address), extra = coalesce(EXCLUDED.extra, b.extra),
      email = coalesce(EXCLUDED.email, b.email), phone = coalesce(EXCLUDED.phone, b.phone), provider = coalesce(EXCLUDED.provider, b.provider),
      customer_id = coalesce(b.customer_id, EXCLUDED.customer_id), job_id = coalesce(b.job_id, EXCLUDED.job_id),
      match_how = coalesce(b.match_how, EXCLUDED.match_how), addr_ok = coalesce(b.addr_ok, EXCLUDED.addr_ok), updated_at = now();
    IF v_was THEN v_upd := v_upd + 1; ELSE v_new := v_new + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('added', v_new, 'updated', v_upd);
END $function$;

-- every booking on a partner's list with its full record, for the workbook download
CREATE OR REPLACE FUNCTION public.partner_bookings_export(p_partner bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE coalesce(jsonb_agg(jsonb_build_object(
    'ref', b.ref, 'booked_at', b.booked_at, 'status', b.status, 'provider', b.provider, 'service_date', b.service_date, 'service', b.service,
    'their_name', b.their_name, 'email', b.email, 'phone', b.phone, 'address', b.address, 'extra', b.extra, 'note', b.note, 'source', b.source,
    'details', coalesce(b.details, '{}'::jsonb)) ORDER BY (CASE WHEN b.ref ~ '^\d+$' THEN b.ref::bigint END) DESC NULLS LAST, b.id DESC), '[]'::jsonb) END
  FROM partner_bookings b WHERE b.partner_id = p_partner
$$;

REVOKE EXECUTE ON FUNCTION public.partner_booking_details_import(bigint, jsonb), public.partner_bookings_export(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.partner_booking_details_import(bigint, jsonb), public.partner_bookings_export(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';


-- =====================================================================
-- Customer page: the HTIN (partner booking list) bookings for one customer, so the
-- booking panel can open beside the customer's Vista notes. Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.customer_partner_bookings(p_customer bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE jsonb_build_object(
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'partner_id', b.partner_id, 'partner', p.name, 'list_name', p.list_name,
        'ref', b.ref, 'booked_at', b.booked_at, 'status', b.status, 'status_at', b.status_at, 'service', b.service, 'service_date', b.service_date,
        'their_name', b.their_name, 'address', b.address, 'extra', b.extra, 'email', b.email, 'provider', b.provider, 'phone', b.phone, 'note', b.note, 'source', b.source,
        'customer_id', b.customer_id, 'customer', c.display_name, 'job_id', b.job_id, 'job', j.job_number, 'job_status', j.status,
        'invoice_id', coalesce(b.invoice_id, i.id), 'invoice', coalesce(bi.invoice_number, i.invoice_number)) ORDER BY coalesce(b.booked_at, b.created_at) DESC, b.id DESC), '[]'::jsonb)
      FROM partner_bookings b JOIN partners p ON p.id = b.partner_id LEFT JOIN customers c ON c.id = b.customer_id LEFT JOIN jobs j ON j.id = b.job_id
      LEFT JOIN invoices bi ON bi.id = b.invoice_id
      LEFT JOIN LATERAL (SELECT i.id, i.invoice_number FROM invoices i WHERE b.invoice_id IS NULL AND i.job_id = b.job_id AND i.status <> 'void' ORDER BY i.invoice_date DESC LIMIT 1) i ON true
      WHERE b.customer_id = p_customer),
    'statuses', (SELECT coalesce(jsonb_agg(DISTINCT jsonb_build_object('status', b2.status)), '[]'::jsonb) FROM partner_bookings b2
      WHERE b2.status IS NOT NULL AND b2.partner_id IN (SELECT partner_id FROM partner_bookings WHERE customer_id = p_customer)),
    'techs', (SELECT coalesce(jsonb_agg(DISTINCT b3.provider), '[]'::jsonb) FROM partner_bookings b3
      WHERE b3.provider IS NOT NULL AND b3.provider <> '-' AND b3.partner_id IN (SELECT partner_id FROM partner_bookings WHERE customer_id = p_customer))) END
$$;
REVOKE EXECUTE ON FUNCTION public.customer_partner_bookings(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_partner_bookings(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- 99zz7_htin_list_cols.sql
-- =====================================================================
-- HTIN List laid out like the HITN portal: the list also gives each booking's sales channel,
-- contract # and service variant (from its full record). Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.partner_bookings_list(p_partner bigint, p_tab text DEFAULT 'all'::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH b AS (SELECT b.*, public._pb_closed(b) closed FROM partner_bookings b WHERE b.partner_id = p_partner)
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE jsonb_build_object(
    'all', (SELECT count(*) FROM b), 'closed', (SELECT count(*) FROM b WHERE closed),
    'statuses', (SELECT coalesce(jsonb_agg(jsonb_build_object('status', status, 'n', n) ORDER BY n DESC), '[]') FROM (SELECT status, count(*) n FROM b WHERE status IS NOT NULL GROUP BY 1) s),
    'closed_statuses', (SELECT to_jsonb(closed_statuses) FROM partners WHERE id = p_partner),
    'list_name', (SELECT list_name FROM partners WHERE id = p_partner),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'ref', b.ref, 'booked_at', b.booked_at, 'status', b.status, 'status_at', b.status_at, 'service', b.service, 'service_date', b.service_date,
        'their_name', b.their_name, 'address', b.address, 'extra', b.extra, 'email', b.email, 'provider', b.provider, 'phone', b.phone, 'channel', b.details ->> 'channel', 'contract', b.details ->> 'contract', 'variant', b.details ->> 'variant', 'closed', b.closed, 'override', b.closed_override, 'note', b.note, 'source', b.source,
        'customer_id', b.customer_id, 'customer', c.display_name, 'how', b.match_how, 'addr_ok', b.addr_ok,
        'job_id', b.job_id, 'job', j.job_number, 'job_status', j.status,
        'visit', (SELECT min(v.scheduled_date) FROM visits v WHERE v.job_id = b.job_id AND v.status <> 'cancelled'),
        'invoice_id', coalesce(b.invoice_id, i.id), 'invoice', coalesce(bi.invoice_number, i.invoice_number), 'balance', coalesce(bi.balance_due, i.balance_due),
        'added_by', public._staff_name(b.added_by)) ORDER BY coalesce(b.booked_at, b.created_at) DESC, b.id DESC), '[]')
      FROM b LEFT JOIN customers c ON c.id = b.customer_id LEFT JOIN jobs j ON j.id = b.job_id
      LEFT JOIN invoices bi ON bi.id = b.invoice_id
      LEFT JOIN LATERAL (SELECT i.id, i.invoice_number, i.balance_due FROM invoices i WHERE b.invoice_id IS NULL AND i.job_id = b.job_id AND i.status <> 'void' ORDER BY i.invoice_date DESC LIMIT 1) i ON true
      WHERE coalesce(p_tab, 'all') = 'all' OR (p_tab = 'closed' AND b.closed) OR (p_tab = 'open' AND NOT b.closed))) END
$function$;
NOTIFY pgrst, 'reload schema';
-- 99zz8_book_for_partner.sql
-- =====================================================================
-- Book a call: who the call is for (Reid or a partner), and for Vista, who pays for the tank
-- (we pay / Vista pays / it's an HTIN booking). Kept on the job in tank_payer: 'reid' | 'partner' | 'htin'.
-- Safe to run more than once.
-- =====================================================================
ALTER TABLE public.jobs ADD COLUMN IF NOT EXISTS tank_payer text;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'jobs_tank_payer_check') THEN
    ALTER TABLE public.jobs ADD CONSTRAINT jobs_tank_payer_check CHECK (tank_payer IS NULL OR tank_payer IN ('reid', 'partner', 'htin'));
  END IF;
END $$;
CREATE OR REPLACE FUNCTION public.book_partners()
RETURNS TABLE (id bigint, name text, list_name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, p.name, p.list_name FROM partners p
  WHERE public.current_staff_role() IS NOT NULL AND p.active
  ORDER BY p.name
$$;

CREATE OR REPLACE FUNCTION public.set_job_tank_payer(p_job bigint, p_who text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_permission('calls.book') AND public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'You don''t have permission to book calls'; END IF;
  IF p_who IS NOT NULL AND p_who NOT IN ('reid', 'partner', 'htin') THEN RAISE EXCEPTION 'Pick who pays for the tank'; END IF;
  UPDATE jobs SET tank_payer = p_who, updated_at = now() WHERE id = p_job;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('jobs', p_job, 'update', public.current_app_user_id(), jsonb_build_object('tank_payer', p_who));
END $$;

REVOKE EXECUTE ON FUNCTION public.book_partners(), public.set_job_tank_payer(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.book_partners(), public.set_job_tank_payer(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
-- 99zz9_tank_service.sql
-- =====================================================================
-- Book a call for Vista: "What is this call?" adds Service Call to who pays for the tank.
-- tank_payer: 'reid' (we pay for the tank) | 'partner' (Vista pays for the tank) | 'service' (service call).
-- Whether it's an HTIN booking is the link to the HTIN List booking. Safe to run more than once.
-- =====================================================================
ALTER TABLE public.jobs ADD COLUMN IF NOT EXISTS tank_payer text;
ALTER TABLE public.jobs DROP CONSTRAINT IF EXISTS jobs_tank_payer_check;
ALTER TABLE public.jobs ADD CONSTRAINT jobs_tank_payer_check CHECK (tank_payer IS NULL OR tank_payer IN ('reid', 'partner', 'service', 'htin'));

CREATE OR REPLACE FUNCTION public.set_job_tank_payer(p_job bigint, p_who text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_permission('calls.book') AND public.current_staff_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'You don''t have permission to book calls'; END IF;
  IF p_who IS NOT NULL AND p_who NOT IN ('reid', 'partner', 'service') THEN RAISE EXCEPTION 'Pick what the call is: we pay for the tank, Vista pays for the tank, or a service call'; END IF;
  UPDATE jobs SET tank_payer = p_who, updated_at = now() WHERE id = p_job;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('jobs', p_job, 'update', public.current_app_user_id(), jsonb_build_object('tank_payer', p_who));
END $$;

REVOKE EXECUTE ON FUNCTION public.set_job_tank_payer(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_job_tank_payer(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
-- 99zz10_hvac_install_dept.sql
-- =====================================================================
-- An "HVAC Install" department (Book a call → Vista → a tank job goes to HVAC Install).
-- Added only if there isn't one already. Safe to run more than once.
-- =====================================================================
INSERT INTO public.business_units (name, trade, sort_order, active)
SELECT 'HVAC Install', 'HVAC', 3, true
WHERE NOT EXISTS (SELECT 1 FROM public.business_units WHERE lower(btrim(name)) LIKE 'hvac install%');

NOTIFY pgrst, 'reload schema';

-- 99zz11_pap_email.sql
-- =====================================================================
-- Security page: EFT / PAP lists by email. A job on GitHub checks eftupload@hsginc.ca every 10 minutes.
-- For each Excel (or CSV) attachment it keeps ONLY the customer #, name and phone columns; the file itself,
-- bank details and every other column are never saved. The list waits on the Security page until an owner
-- reviews it and clicks Mark; nothing changes on its own. Needs 99zz. Safe to run more than once.
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.pap_inbox (
  id           bigserial PRIMARY KEY,
  message_id   text NOT NULL,
  received_at  timestamptz,
  from_addr    text,
  from_name    text,
  subject      text,
  file_name    text,
  pap_list     text NOT NULL DEFAULT 'monthly' CHECK (pap_list IN ('monthly', 'other')),
  head         jsonb,             -- the three column names found in the file: [customer #, name, phone]
  rows         jsonb,             -- [[customer #, name, phone], ...] only
  note         text,              -- why it couldn't be read, if it couldn't
  status       text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'done', 'ignored', 'unreadable')),
  done_at      timestamptz,
  done_by      bigint,
  created_at   timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX IF NOT EXISTS pap_inbox_file_key ON public.pap_inbox (message_id, coalesce(file_name, ''));
CREATE INDEX IF NOT EXISTS pap_inbox_status_idx ON public.pap_inbox (status, received_at DESC);
ALTER TABLE public.pap_inbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_inbox FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.pap_inbox_seen (message_id text PRIMARY KEY, seen_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.pap_inbox_seen ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_inbox_seen FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.pap_inbox_state (key text PRIMARY KEY, value text, updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.pap_inbox_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_inbox_state FROM anon, authenticated;

-- What's in the EFT mailbox (owners only): the lists waiting, plus the last 20 handled
CREATE OR REPLACE FUNCTION public.pap_inbox_list()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE jsonb_build_object(
    'last_check', (SELECT value FROM pap_inbox_state WHERE key = 'last_check'),
    'last_error', (SELECT value FROM pap_inbox_state WHERE key = 'last_error'),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'received', m.received_at, 'from', coalesce(nullif(m.from_name, ''), m.from_addr),
               'from_addr', m.from_addr, 'subject', m.subject, 'file', m.file_name, 'list', m.pap_list, 'head', m.head,
               'count', coalesce(jsonb_array_length(m.rows), 0), 'note', m.note, 'status', m.status, 'done_at', m.done_at,
               'done_by', public._emp_name((SELECT u.employee_id FROM app_users u WHERE u.id = m.done_by)))
             ORDER BY (m.status IN ('waiting', 'unreadable')) DESC, m.received_at DESC NULLS LAST, m.id DESC), '[]')
             FROM (SELECT * FROM pap_inbox WHERE status IN ('waiting', 'unreadable')
                   UNION ALL
                   (SELECT * FROM pap_inbox WHERE status IN ('done', 'ignored') ORDER BY coalesce(done_at, created_at) DESC LIMIT 20)) m)) END
$$;

-- The rows of one emailed list (only the three columns), to review and match
CREATE OR REPLACE FUNCTION public.pap_inbox_rows(p_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE
    (SELECT jsonb_build_object('file', file_name, 'list', pap_list, 'head', head, 'rows', coalesce(rows, '[]')) FROM pap_inbox WHERE id = p_id) END
$$;

-- Mark an emailed list as done (after Mark) or ignored. Once handled, its rows are cleared: they aren't needed any more.
CREATE OR REPLACE FUNCTION public.pap_inbox_set(p_id bigint, p_status text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF p_status NOT IN ('done', 'ignored', 'waiting') THEN RAISE EXCEPTION 'Unknown status'; END IF;
  UPDATE pap_inbox SET status = p_status,
         done_at = CASE WHEN p_status = 'waiting' THEN NULL ELSE now() END,
         done_by = CASE WHEN p_status = 'waiting' THEN NULL ELSE public.current_app_user_id() END,
         rows = CASE WHEN p_status = 'waiting' THEN rows ELSE NULL END
  WHERE id = p_id AND (p_status <> 'waiting' OR rows IS NOT NULL);
END $$;

REVOKE EXECUTE ON FUNCTION public.pap_inbox_list(), public.pap_inbox_rows(bigint), public.pap_inbox_set(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_inbox_list(), public.pap_inbox_rows(bigint), public.pap_inbox_set(bigint, text) TO authenticated;

-- 99zz12_eft_mail_archive.sql
-- =====================================================================
-- Security page: keep every email sent to eftupload@hsginc.ca, with its attachments, so owners can look at
-- them any time. The attachments (the EFT Excel files) have bank details in them, so only owners can see
-- them, and every time someone opens or downloads a file it's written to History. Needs 99zz11.
-- Safe to run more than once.
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.pap_mail (
  id           bigserial PRIMARY KEY,
  message_id   text NOT NULL UNIQUE,
  received_at  timestamptz,
  from_addr    text,
  from_name    text,
  to_addr      text,
  cc_addr      text,
  subject      text,
  body_text    text,
  raw          bytea,             -- the whole email, exactly as it arrived (download as .eml)
  raw_size     integer,
  created_at   timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS pap_mail_received_idx ON public.pap_mail (received_at DESC NULLS LAST, id DESC);
ALTER TABLE public.pap_mail ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_mail FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.pap_mail_file (
  id           bigserial PRIMARY KEY,
  mail_id      bigint NOT NULL REFERENCES public.pap_mail(id) ON DELETE CASCADE,
  file_name    text,
  mime         text,
  size         integer,
  data         bytea);
CREATE INDEX IF NOT EXISTS pap_mail_file_mail_idx ON public.pap_mail_file (mail_id);
ALTER TABLE public.pap_mail_file ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_mail_file FROM anon, authenticated;

-- each emailed list points back to its email and file
ALTER TABLE public.pap_inbox ADD COLUMN IF NOT EXISTS mail_id bigint REFERENCES public.pap_mail(id) ON DELETE SET NULL;
ALTER TABLE public.pap_inbox ADD COLUMN IF NOT EXISTS file_id bigint REFERENCES public.pap_mail_file(id) ON DELETE SET NULL;

-- All the emails (owners only), newest first; p_q looks in sender, subject, words and file names
CREATE OR REPLACE FUNCTION public.pap_mail_list(p_q text DEFAULT NULL, p_limit integer DEFAULT 200)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE jsonb_build_object(
    'total', (SELECT count(*) FROM pap_mail),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'received', m.received_at, 'from', coalesce(nullif(m.from_name, ''), m.from_addr),
               'from_addr', m.from_addr, 'subject', m.subject,
               'files', (SELECT coalesce(jsonb_agg(f.file_name ORDER BY f.id), '[]') FROM pap_mail_file f WHERE f.mail_id = m.id),
               'list_status', (SELECT string_agg(DISTINCT i.status, ',') FROM pap_inbox i WHERE i.mail_id = m.id))
             ORDER BY m.received_at DESC NULLS LAST, m.id DESC), '[]')
             FROM (SELECT * FROM pap_mail x
                   WHERE nullif(btrim(p_q), '') IS NULL
                      OR concat_ws(' ', x.from_name, x.from_addr, x.subject, x.body_text,
                                   (SELECT string_agg(f.file_name, ' ') FROM pap_mail_file f WHERE f.mail_id = x.id)) ILIKE '%' || btrim(p_q) || '%'
                   ORDER BY x.received_at DESC NULLS LAST, x.id DESC LIMIT least(coalesce(p_limit, 200), 1000)) m)) END
$$;

-- One email: who, when, the words, and its attachments (names and sizes, not the files)
CREATE OR REPLACE FUNCTION public.pap_mail_get(p_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE
    (SELECT jsonb_build_object('id', m.id, 'received', m.received_at, 'from_name', m.from_name, 'from_addr', m.from_addr,
              'to', m.to_addr, 'cc', m.cc_addr, 'subject', m.subject, 'body', m.body_text, 'raw_size', m.raw_size,
              'files', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'name', f.file_name, 'mime', f.mime, 'size', f.size) ORDER BY f.id), '[]')
                        FROM pap_mail_file f WHERE f.mail_id = m.id))
     FROM pap_mail m WHERE m.id = p_id) END
$$;

-- Open / download an attachment (or, with p_raw, the whole email). Written to History, since these files hold bank details.
CREATE OR REPLACE FUNCTION public.pap_mail_file(p_id bigint, p_raw boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF p_raw THEN
    SELECT jsonb_build_object('name', coalesce(nullif(regexp_replace(coalesce(subject, ''), '[^A-Za-z0-9 _.-]+', '', 'g'), ''), 'email') || '.eml',
                              'mime', 'message/rfc822', 'b64', encode(raw, 'base64'))
      INTO r FROM pap_mail WHERE id = p_id AND raw IS NOT NULL;
  ELSE
    SELECT jsonb_build_object('name', file_name, 'mime', mime, 'b64', encode(data, 'base64')) INTO r FROM pap_mail_file WHERE id = p_id;
  END IF;
  IF r IS NOT NULL THEN
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
    VALUES (CASE WHEN p_raw THEN 'pap_mail' ELSE 'pap_mail_file' END, p_id, 'update', public.current_app_user_id(),
            jsonb_build_object('change', 'opened EFT email ' || CASE WHEN p_raw THEN 'message' ELSE 'file' END, 'file', r ->> 'name'));
  END IF;
  RETURN r;
END $$;

-- Emailed lists now keep their rows after they're marked or ignored (so you can look back at them)
CREATE OR REPLACE FUNCTION public.pap_inbox_set(p_id bigint, p_status text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF p_status NOT IN ('done', 'ignored', 'waiting') THEN RAISE EXCEPTION 'Unknown status'; END IF;
  UPDATE pap_inbox SET status = p_status,
         done_at = CASE WHEN p_status = 'waiting' THEN NULL ELSE now() END,
         done_by = CASE WHEN p_status = 'waiting' THEN NULL ELSE public.current_app_user_id() END
  WHERE id = p_id AND (p_status <> 'waiting' OR rows IS NOT NULL);
END $$;

-- the emailed-lists box also gets the email each list came from
CREATE OR REPLACE FUNCTION public.pap_inbox_list()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE jsonb_build_object(
    'last_check', (SELECT value FROM pap_inbox_state WHERE key = 'last_check'),
    'last_error', (SELECT value FROM pap_inbox_state WHERE key = 'last_error'),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'mail_id', m.mail_id, 'received', m.received_at, 'from', coalesce(nullif(m.from_name, ''), m.from_addr),
               'from_addr', m.from_addr, 'subject', m.subject, 'file', m.file_name, 'list', m.pap_list, 'head', m.head,
               'count', coalesce(jsonb_array_length(m.rows), 0), 'note', m.note, 'status', m.status, 'done_at', m.done_at,
               'done_by', public._emp_name((SELECT u.employee_id FROM app_users u WHERE u.id = m.done_by)))
             ORDER BY (m.status IN ('waiting', 'unreadable')) DESC, m.received_at DESC NULLS LAST, m.id DESC), '[]')
             FROM (SELECT * FROM pap_inbox WHERE status IN ('waiting', 'unreadable')
                   UNION ALL
                   (SELECT * FROM pap_inbox WHERE status IN ('done', 'ignored') ORDER BY coalesce(done_at, created_at) DESC LIMIT 20)) m)) END
$$;

REVOKE EXECUTE ON FUNCTION public.pap_mail_list(text, integer), public.pap_mail_get(bigint), public.pap_mail_file(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_mail_list(text, integer), public.pap_mail_get(bigint), public.pap_mail_file(bigint, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
"""

# small pieces that only add functions (no table changes), applied on their own so a lock on APP_SCHEMA can't hold them up
EXTRA_SCHEMA = r"""
-- 99zzz3_amount_search.sql (its indexes are in the setup file only: adding them here locked the invoices table)
-- =====================================================================
-- Receivables: find by amount. Type an amount and see every invoice (any date, paid or not) whose total,
-- amount paid or balance owing is exactly that amount, to the cent. Same people as Receivables.
-- Safe to run more than once.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.invoice_amount_search(p_amount numeric)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH a AS (SELECT round(p_amount, 2) AS v),
  hit AS (
    SELECT i.id FROM invoices i, a WHERE i.total = a.v
    UNION SELECT i.id FROM invoices i, a WHERE i.balance_due = a.v
    UNION SELECT i.id FROM invoices i, a WHERE i.amount_paid = a.v),
  p AS (
    SELECT i.* FROM invoices i JOIN hit h ON h.id = i.id
    WHERE (public.has_permission('invoices.adjust') OR coalesce(public.current_staff_role() IN ('owner', 'admin', 'accounting'), false))
      AND p_amount IS NOT NULL AND i.status NOT IN ('void', 'draft'))
  SELECT jsonb_build_object(
    'amount', (SELECT v FROM a),
    'n', (SELECT count(*) FROM p),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object(
               'invoice_id', x.id, 'invoice_number', x.invoice_number, 'invoice_date', x.invoice_date, 'status', x.status,
               'total', x.total, 'paid', x.amount_paid, 'balance', x.balance_due,
               'on_total', x.total = (SELECT v FROM a), 'on_paid', x.amount_paid = (SELECT v FROM a), 'on_balance', x.balance_due = (SELECT v FROM a),
               'customer_id', c.id, 'customer_name', c.display_name, 'customer_number', c.customer_number, 'street', l.street, 'city', l.city,
               'job_type', t.name) ORDER BY x.invoice_date DESC, x.id DESC), '[]')
             FROM (SELECT * FROM p ORDER BY invoice_date DESC, id DESC LIMIT 500) x
             JOIN customers c ON c.id = x.customer_id
             LEFT JOIN locations l ON l.id = x.location_id
             LEFT JOIN jobs j ON j.id = x.job_id
             LEFT JOIN job_types t ON t.id = j.job_type_id))
$$;
ALTER FUNCTION public.invoice_amount_search(numeric) SET jit = off;
REVOKE EXECUTE ON FUNCTION public.invoice_amount_search(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invoice_amount_search(numeric) TO authenticated;

-- 99zzz4_eft_people.sql
-- =====================================================================
-- Security page: "People in the EFT files". Everyone in the emailed EFT lists, once each (the newest file they're in),
-- matched to the customer in the database the same way as Review (customer #, then phone, then exact name).
-- Owners only. Needs 99zz and 99zz11. Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.pap_file_people()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '60s' AS $$
DECLARE v jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RETURN NULL; END IF;
  WITH e AS (
    SELECT i.id AS inbox_id, i.mail_id, i.file_name, i.received_at, i.pap_list AS file_list,
           btrim(coalesce(x ->> 0, '')) AS num, btrim(coalesce(x ->> 1, '')) AS name, btrim(coalesce(x ->> 2, '')) AS phone
    FROM pap_inbox i, jsonb_array_elements(i.rows) x
    WHERE i.rows IS NOT NULL AND i.status <> 'ignored' AND jsonb_typeof(x) = 'array'),
  k AS (SELECT e.*, coalesce(nullif(lower(e.num), ''), lower(e.name) || '|' || right(regexp_replace(e.phone, '\D', '', 'g'), 10)) AS key FROM e
        WHERE e.num <> '' OR e.name <> '' OR e.phone <> ''),
  c AS (SELECT key, count(DISTINCT inbox_id) AS files FROM k GROUP BY key),
  r AS (SELECT DISTINCT ON (k.key) k.*, c.files, (row_number() OVER ())::int AS n
        FROM k JOIN c USING (key) ORDER BY k.key, k.received_at DESC NULLS LAST, k.inbox_id DESC),
  m AS (SELECT * FROM public.pap_match((SELECT coalesce(jsonb_agg(jsonb_build_object('i', r.n, 'num', r.num, 'name', r.name, 'phone', r.phone)), '[]') FROM r)))
  SELECT jsonb_build_object(
    'n', (SELECT count(*) FROM r),
    'found', (SELECT count(*) FROM m),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
       'num', r.num, 'name', r.name, 'phone', r.phone, 'file', r.file_name, 'received', r.received_at, 'mail_id', r.mail_id,
       'file_list', r.file_list, 'files', r.files,
       'customer_id', m.customer_id, 'customer_number', m.customer_number, 'customer_name', m.name, 'how', m.how, 'pap_list', m.pap_list,
       'address', (SELECT concat_ws(', ', l.street, l.city) FROM locations l WHERE l.customer_id = m.customer_id ORDER BY l.active DESC, l.id LIMIT 1))
       ORDER BY lower(coalesce(nullif(r.name, ''), m.name, r.num))), '[]'))
  INTO v
  FROM r LEFT JOIN m ON m.i = r.n;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION public.pap_file_people() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_file_people() TO authenticated;

-- 99zzz5_pap_list_save.sql
-- =====================================================================
-- Security page: when an owner clicks Mark (an emailed list or a file uploaded by hand), the customer #, name and phone
-- columns of that file are kept, so "People in the EFT files" is built from both. Nothing else from the file is sent.
-- Also: the emailed-lists box says which file each list came from (so it can be opened and its columns picked by hand).
-- Needs 99zz11 and 99zz12. Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.pap_inbox_save(p_id bigint, p_file text, p_list text, p_head jsonb, p_rows jsonb)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id bigint; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF p_list NOT IN ('monthly', 'other') THEN RAISE EXCEPTION 'Pick a list'; END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'No rows'; END IF;
  -- keep only three short text values per row, whatever was sent
  p_rows := (SELECT coalesce(jsonb_agg(jsonb_build_array(left(coalesce(x ->> 0, ''), 60), left(coalesce(x ->> 1, ''), 200), left(coalesce(x ->> 2, ''), 40))), '[]')
             FROM jsonb_array_elements(p_rows) x WHERE jsonb_typeof(x) = 'array');
  IF p_id IS NOT NULL THEN
    UPDATE pap_inbox SET head = p_head, rows = p_rows, pap_list = p_list, note = NULL, status = 'done', done_at = now(), done_by = v_me
    WHERE id = p_id RETURNING id INTO v_id;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO pap_inbox (message_id, received_at, from_name, subject, file_name, pap_list, head, rows, status, done_at, done_by)
    VALUES ('upload:' || gen_random_uuid(), now(), coalesce(public._emp_name((SELECT employee_id FROM app_users WHERE id = v_me)), 'Uploaded'),
            'Uploaded on the Security page', left(coalesce(p_file, 'Uploaded file'), 200), p_list, p_head, p_rows, 'done', now(), v_me)
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.pap_inbox_save(bigint, text, text, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_inbox_save(bigint, text, text, jsonb, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.pap_inbox_list()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE jsonb_build_object(
    'last_check', (SELECT value FROM pap_inbox_state WHERE key = 'last_check'),
    'last_error', (SELECT value FROM pap_inbox_state WHERE key = 'last_error'),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'mail_id', m.mail_id, 'file_id', m.file_id, 'received', m.received_at,
               'from', coalesce(nullif(m.from_name, ''), m.from_addr), 'from_addr', m.from_addr, 'subject', m.subject, 'file', m.file_name,
               'list', m.pap_list, 'head', m.head, 'count', coalesce(jsonb_array_length(m.rows), 0), 'note', m.note, 'status', m.status,
               'upload', m.message_id LIKE 'upload:%', 'done_at', m.done_at,
               'done_by', public._emp_name((SELECT u.employee_id FROM app_users u WHERE u.id = m.done_by)))
             ORDER BY (m.status IN ('waiting', 'unreadable')) DESC, m.received_at DESC NULLS LAST, m.id DESC), '[]')
             FROM (SELECT * FROM pap_inbox WHERE status IN ('waiting', 'unreadable')
                   UNION ALL
                   (SELECT * FROM pap_inbox WHERE status IN ('done', 'ignored') ORDER BY coalesce(done_at, created_at) DESC LIMIT 20)) m)) END
$$;

-- 99zzz6_pap_match_better.sql
-- =====================================================================
-- Security page: better matching of EFT / PAP files to customers (Review, uploads and People in the EFT files).
--   1. Customer #: as written, or without a "C" / "C#" in front ("C#758" -> 758). It only counts when the name in the
--      file looks like the customer (a word of it is in the customer's name), so a wrong number can't match the wrong person.
--   2. Address code: "616bo" = the customer whose address starts "616 Bo..." (only when one customer has it).
--   3. Phone.
--   4. Name: "First Last", "Last, First", and each person of "John & Linda Albert" (only when one customer has it).
-- People in the EFT files also shows each person's amount and the bank's response (Approved, NSF...).
-- Needs 99zz, 99zzz4, 99zzz5. Safe to run more than once.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.pap_match(p_rows jsonb)
RETURNS TABLE (i int, customer_id bigint, customer_number text, name text, how text, pap_list text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '60s' AS $$
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  RETURN QUERY
  WITH r0 AS MATERIALIZED (
    SELECT x.i, nullif(regexp_replace(btrim(coalesce(x.num, '')), '\.0+$', ''), '') AS num,
           nullif(btrim(regexp_replace(lower(replace(coalesce(x.name, ''), '&amp;', '&')), '\s+', ' ', 'g')), '') AS nm,
           nullif(right(regexp_replace(coalesce(x.phone, ''), '\D', '', 'g'), 10), '') AS ph
    FROM jsonb_to_recordset(p_rows) AS x(i int, num text, name text, phone text)),
  r AS MATERIALIZED (
    SELECT r0.*,
           nullif(regexp_replace(r0.num, '^[Cc]\s*#\s*|^[Cc](?=[0-9])', ''), '') AS num2,
           CASE WHEN r0.num ~ '^[0-9]{1,6}\s*[A-Za-z]{2,}$' THEN substring(r0.num from '^[0-9]+') END AS a_no,
           CASE WHEN r0.num ~ '^[0-9]{1,6}\s*[A-Za-z]{2,}$' THEN lower(substring(r0.num from '[A-Za-z]+$')) END AS a_st,
           (SELECT array_agg(w) FROM regexp_split_to_table(coalesce(r0.nm, ''), '[^a-z0-9]+') w
             WHERE length(w) >= 3 AND w NOT IN ('and', 'the', 'inc', 'ltd', 'canada', 'ont', 'ontario', 'corp', 'dr')) AS words
    FROM r0),
  -- name versions: whole name, "first last" and "last, first" for each first name in "John & Linda Albert"
  nv AS MATERIALIZED (
    SELECT DISTINCT r.i, v FROM r,
      LATERAL (SELECT substring(r.nm from '(\S+)$') AS last, regexp_replace(r.nm, '\s*\S+$', '') AS rest) p,
      LATERAL (SELECT r.nm AS v
               UNION ALL SELECT btrim(f) || ' ' || p.last FROM regexp_split_to_table(p.rest, '\s*&\s*|\s+and\s+') f WHERE btrim(f) <> '' AND p.rest <> ''
               UNION ALL SELECT p.last || ', ' || btrim(f) FROM regexp_split_to_table(p.rest, '\s*&\s*|\s+and\s+') f WHERE btrim(f) <> '' AND p.rest <> '') vv
    WHERE r.nm IS NOT NULL),
  byname AS MATERIALIZED (SELECT nv.i, min(c.id) AS id, count(DISTINCT c.id) AS n FROM nv
             JOIN customers c ON lower(btrim(c.display_name)) = nv.v AND c.merged_into_id IS NULL GROUP BY nv.i),
  byphone AS MATERIALIZED (SELECT right(regexp_replace(k.value, '\D', '', 'g'), 10) AS ph, min(k.customer_id) AS id, count(DISTINCT k.customer_id) AS n FROM customer_contacts k
              WHERE k.kind IN ('phone', 'mobile') AND right(regexp_replace(k.value, '\D', '', 'g'), 10) IN (SELECT r.ph FROM r WHERE length(r.ph) = 10) GROUP BY 1),
  byaddr AS MATERIALIZED (SELECT r.i, min(coalesce(c.merged_into_id, c.id)) AS id, count(DISTINCT coalesce(c.merged_into_id, c.id)) AS n
              FROM r JOIN locations l ON r.a_no IS NOT NULL AND split_part(btrim(l.street), ' ', 1) = r.a_no
                AND lower(regexp_replace(btrim(l.street), '^[0-9]+\s*', '')) LIKE r.a_st || '%'
              JOIN customers c ON c.id = l.customer_id
              GROUP BY r.i),
  bynum AS MATERIALIZED (
    SELECT r.i, (SELECT c.id FROM customers c
                 WHERE (c.customer_number IN (r.num, r.num2) OR (r.num2 ~ '^[0-9]{1,15}$' AND c.st_id = CASE WHEN r.num2 ~ '^[0-9]{1,15}$' THEN r.num2::bigint END))
                   AND (r.words IS NULL OR EXISTS (SELECT 1 FROM unnest(r.words) w WHERE position(w IN lower(c.display_name)) > 0))
                 ORDER BY (c.customer_number = r.num) DESC, c.merged_into_id IS NULL DESC, c.id LIMIT 1) AS id
    FROM r WHERE r.num IS NOT NULL),
  m AS MATERIALIZED (
    SELECT r.i, bn.id AS by_num, CASE WHEN a.n = 1 THEN a.id END AS by_addr, CASE WHEN p.n = 1 THEN p.id END AS by_phone, CASE WHEN b.n = 1 THEN b.id END AS by_name
    FROM r
    LEFT JOIN bynum bn ON bn.i = r.i
    LEFT JOIN byaddr a ON a.i = r.i
    LEFT JOIN byphone p ON p.ph = r.ph
    LEFT JOIN byname b ON b.i = r.i)
  SELECT m.i, c.id, c.customer_number, c.display_name,
         CASE WHEN m.by_num IS NOT NULL THEN 'number' WHEN m.by_addr IS NOT NULL THEN 'address' WHEN m.by_phone IS NOT NULL THEN 'phone' ELSE 'name' END,
         c.pap_list
  FROM m
  JOIN customers c0 ON c0.id = coalesce(m.by_num, m.by_addr, m.by_phone, m.by_name)
  JOIN customers c ON c.id = coalesce(c0.merged_into_id, c0.id);
END $$;

-- the file's own table (every column except bank details), to show it the way the bank sends it
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pap_inbox' AND column_name = 'tbl') THEN
    ALTER TABLE public.pap_inbox ADD COLUMN cols jsonb, ADD COLUMN tbl jsonb;
  END IF;
END $$;

-- Mark (an emailed list or a file uploaded by hand): keep the matching values (customer #, name, phone, amount, response)
-- and the file's table. p_cols / p_tbl never hold bank columns: the page leaves those out before sending.
DROP FUNCTION IF EXISTS public.pap_inbox_save(bigint, text, text, jsonb, jsonb);
CREATE OR REPLACE FUNCTION public.pap_inbox_save(p_id bigint, p_file text, p_list text, p_head jsonb, p_rows jsonb, p_cols jsonb DEFAULT NULL, p_tbl jsonb DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id bigint; v_me bigint := public.current_app_user_id();
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF p_list NOT IN ('monthly', 'other') THEN RAISE EXCEPTION 'Pick a list'; END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'No rows'; END IF;
  p_rows := (SELECT coalesce(jsonb_agg(jsonb_build_array(left(coalesce(x ->> 0, ''), 60), left(coalesce(x ->> 1, ''), 200), left(coalesce(x ->> 2, ''), 40),
                                                         left(coalesce(x ->> 3, ''), 20), left(coalesce(x ->> 4, ''), 80)) ORDER BY k), '[]')
             FROM jsonb_array_elements(p_rows) WITH ORDINALITY t(x, k) WHERE jsonb_typeof(x) = 'array');
  IF p_tbl IS NOT NULL AND (jsonb_typeof(p_tbl) <> 'array' OR jsonb_array_length(p_tbl) <> jsonb_array_length(p_rows)) THEN p_tbl := NULL; p_cols := NULL; END IF;
  IF p_id IS NOT NULL THEN
    UPDATE pap_inbox SET head = p_head, rows = p_rows, pap_list = p_list, note = NULL, status = 'done', done_at = now(), done_by = v_me,
           cols = coalesce(p_cols, cols), tbl = CASE WHEN p_tbl IS NOT NULL THEN p_tbl WHEN jsonb_array_length(coalesce(tbl, '[]')) = jsonb_array_length(p_rows) THEN tbl END
    WHERE id = p_id RETURNING id INTO v_id;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO pap_inbox (message_id, received_at, from_name, subject, file_name, pap_list, head, rows, cols, tbl, status, done_at, done_by)
    VALUES ('upload:' || gen_random_uuid(), now(), coalesce(public._emp_name((SELECT employee_id FROM app_users WHERE id = v_me)), 'Uploaded'),
            'Uploaded on the Security page', left(coalesce(p_file, 'Uploaded file'), 200), p_list, p_head, p_rows, p_cols, p_tbl, 'done', now(), v_me)
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.pap_inbox_save(bigint, text, text, jsonb, jsonb, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_inbox_save(bigint, text, text, jsonb, jsonb, jsonb, jsonb) TO authenticated;

-- The EFT files that can be shown (newest first)
CREATE OR REPLACE FUNCTION public.pap_file_list()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE
    (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'file', i.file_name, 'received', i.received_at, 'status', i.status, 'list', i.pap_list,
              'count', jsonb_array_length(i.rows), 'upload', i.message_id LIKE 'upload:%', 'mail_id', i.mail_id) ORDER BY i.received_at DESC NULLS LAST, i.id DESC), '[]')
     FROM pap_inbox i WHERE i.rows IS NOT NULL AND jsonb_array_length(i.rows) > 0 AND i.status <> 'ignored') END
$$;

-- One EFT file, the way the bank sent it, with the customer each row matches
CREATE OR REPLACE FUNCTION public.pap_file_view(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '60s' AS $$
DECLARE v jsonb; f pap_inbox;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RETURN NULL; END IF;
  SELECT * INTO f FROM pap_inbox WHERE id = p_id;
  IF f.id IS NULL OR f.rows IS NULL THEN RETURN NULL; END IF;
  WITH k AS (SELECT (t.k)::int AS n, t.x FROM jsonb_array_elements(f.rows) WITH ORDINALITY t(x, k)),
  m AS (SELECT * FROM public.pap_match((SELECT coalesce(jsonb_agg(jsonb_build_object('i', k.n, 'num', k.x ->> 0, 'name', k.x ->> 1, 'phone', k.x ->> 2)), '[]') FROM k)))
  SELECT jsonb_build_object('id', f.id, 'file', f.file_name, 'received', f.received_at, 'list', f.pap_list, 'status', f.status, 'mail_id', f.mail_id,
      'cols', coalesce(f.cols, '["Customer #", "Name", "Phone", "Amount", "Response"]'::jsonb),
      'n', (SELECT count(*) FROM k), 'found', (SELECT count(*) FROM m),
      'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object(
          'cells', coalesce(f.tbl -> (k.n - 1), k.x), 'num', k.x ->> 0, 'name', k.x ->> 1, 'amount', k.x ->> 3, 'response', k.x ->> 4,
          'customer_id', m.customer_id, 'customer_number', m.customer_number, 'customer_name', m.name, 'how', m.how, 'pap_list', m.pap_list,
          'address', (SELECT concat_ws(', ', l.street, l.city) FROM locations l WHERE l.customer_id = m.customer_id ORDER BY l.active DESC, l.id LIMIT 1))
        ORDER BY k.n), '[]') FROM k LEFT JOIN m ON m.i = k.n))
  INTO v;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION public.pap_file_list(), public.pap_file_view(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_file_list(), public.pap_file_view(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.pap_file_people()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '60s' AS $$
DECLARE v jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RETURN NULL; END IF;
  WITH e AS (
    SELECT i.id AS inbox_id, i.mail_id, i.file_name, i.received_at, i.pap_list AS file_list,
           btrim(coalesce(x ->> 0, '')) AS num, btrim(replace(coalesce(x ->> 1, ''), '&amp;', '&')) AS name, btrim(coalesce(x ->> 2, '')) AS phone,
           btrim(coalesce(x ->> 3, '')) AS amount, btrim(coalesce(x ->> 4, '')) AS response
    FROM pap_inbox i, jsonb_array_elements(i.rows) x
    WHERE i.rows IS NOT NULL AND i.status <> 'ignored' AND jsonb_typeof(x) = 'array'),
  k AS (SELECT e.*, coalesce(nullif(lower(e.num), ''), lower(e.name) || '|' || right(regexp_replace(e.phone, '\D', '', 'g'), 10)) || '|' || lower(e.name) AS key FROM e
        WHERE e.num <> '' OR e.name <> '' OR e.phone <> ''),
  c AS (SELECT key, count(DISTINCT inbox_id) AS files FROM k GROUP BY key),
  r AS (SELECT DISTINCT ON (k.key) k.*, c.files, (row_number() OVER ())::int AS n
        FROM k JOIN c USING (key) ORDER BY k.key, k.received_at DESC NULLS LAST, k.inbox_id DESC),
  m AS (SELECT * FROM public.pap_match((SELECT coalesce(jsonb_agg(jsonb_build_object('i', r.n, 'num', r.num, 'name', r.name, 'phone', r.phone)), '[]') FROM r)))
  SELECT jsonb_build_object(
    'n', (SELECT count(*) FROM r),
    'found', (SELECT count(*) FROM m),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
       'num', r.num, 'name', r.name, 'phone', r.phone, 'amount', r.amount, 'response', r.response,
       'file', r.file_name, 'received', r.received_at, 'mail_id', r.mail_id, 'file_list', r.file_list, 'files', r.files,
       'customer_id', m.customer_id, 'customer_number', m.customer_number, 'customer_name', m.name, 'how', m.how, 'pap_list', m.pap_list,
       'address', (SELECT concat_ws(', ', l.street, l.city) FROM locations l WHERE l.customer_id = m.customer_id ORDER BY l.active DESC, l.id LIMIT 1))
       ORDER BY lower(coalesce(nullif(r.name, ''), m.name, r.num))), '[]'))
  INTO v
  FROM r LEFT JOIN m ON m.i = r.n;
  RETURN v;
END $$;

-- 99zzz7_pap_links.sql
-- =====================================================================
-- Security page, EFT lists: click a row to see the customer's details; for a row that wasn't found (or was matched to the
-- wrong person), search for the customer and link them by hand. The link is remembered (by the name and reference in the
-- bank's file), so the same person matches on their own in later files too. Owners only.
-- Needs 99zzz6. Safe to run more than once.
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.pap_links (
  id           bigserial PRIMARY KEY,
  name_key     text NOT NULL,
  ref_key      text NOT NULL DEFAULT '',
  customer_id  bigint NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  set_by       bigint,
  set_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (name_key, ref_key));
ALTER TABLE public.pap_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pap_links FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.pap_match(p_rows jsonb)
RETURNS TABLE (i int, customer_id bigint, customer_number text, name text, how text, pap_list text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '60s' AS $$
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  RETURN QUERY
  WITH r0 AS MATERIALIZED (
    SELECT x.i, nullif(regexp_replace(btrim(coalesce(x.num, '')), '\.0+$', ''), '') AS num,
           nullif(btrim(regexp_replace(lower(replace(coalesce(x.name, ''), '&amp;', '&')), '\s+', ' ', 'g')), '') AS nm,
           nullif(right(regexp_replace(coalesce(x.phone, ''), '\D', '', 'g'), 10), '') AS ph
    FROM jsonb_to_recordset(p_rows) AS x(i int, num text, name text, phone text)),
  r AS MATERIALIZED (
    SELECT r0.*,
           nullif(regexp_replace(r0.num, '^[Cc]\s*#\s*|^[Cc](?=[0-9])', ''), '') AS num2,
           CASE WHEN r0.num ~ '^[0-9]{1,6}\s*[A-Za-z]{2,}$' THEN substring(r0.num from '^[0-9]+') END AS a_no,
           CASE WHEN r0.num ~ '^[0-9]{1,6}\s*[A-Za-z]{2,}$' THEN lower(substring(r0.num from '[A-Za-z]+$')) END AS a_st,
           (SELECT array_agg(w) FROM regexp_split_to_table(coalesce(r0.nm, ''), '[^a-z0-9]+') w
             WHERE length(w) >= 3 AND w NOT IN ('and', 'the', 'inc', 'ltd', 'canada', 'ont', 'ontario', 'corp', 'dr')) AS words
    FROM r0),
  -- name versions: whole name, "first last" and "last, first" for each first name in "John & Linda Albert"
  nv AS MATERIALIZED (
    SELECT DISTINCT r.i, v FROM r,
      LATERAL (SELECT substring(r.nm from '(\S+)$') AS last, regexp_replace(r.nm, '\s*\S+$', '') AS rest) p,
      LATERAL (SELECT r.nm AS v
               UNION ALL SELECT btrim(f) || ' ' || p.last FROM regexp_split_to_table(p.rest, '\s*&\s*|\s+and\s+') f WHERE btrim(f) <> '' AND p.rest <> ''
               UNION ALL SELECT p.last || ', ' || btrim(f) FROM regexp_split_to_table(p.rest, '\s*&\s*|\s+and\s+') f WHERE btrim(f) <> '' AND p.rest <> '') vv
    WHERE r.nm IS NOT NULL),
  byname AS MATERIALIZED (SELECT nv.i, min(c.id) AS id, count(DISTINCT c.id) AS n FROM nv
             JOIN customers c ON lower(btrim(c.display_name)) = nv.v AND c.merged_into_id IS NULL GROUP BY nv.i),
  byphone AS MATERIALIZED (SELECT right(regexp_replace(k.value, '\D', '', 'g'), 10) AS ph, min(k.customer_id) AS id, count(DISTINCT k.customer_id) AS n FROM customer_contacts k
              WHERE k.kind IN ('phone', 'mobile') AND right(regexp_replace(k.value, '\D', '', 'g'), 10) IN (SELECT r.ph FROM r WHERE length(r.ph) = 10) GROUP BY 1),
  byaddr AS MATERIALIZED (SELECT r.i, min(coalesce(c.merged_into_id, c.id)) AS id, count(DISTINCT coalesce(c.merged_into_id, c.id)) AS n
              FROM r JOIN locations l ON r.a_no IS NOT NULL AND split_part(btrim(l.street), ' ', 1) = r.a_no
                AND lower(regexp_replace(btrim(l.street), '^[0-9]+\s*', '')) LIKE r.a_st || '%'
              JOIN customers c ON c.id = l.customer_id
              GROUP BY r.i),
  bynum AS MATERIALIZED (
    SELECT r.i, (SELECT c.id FROM customers c
                 WHERE (c.customer_number IN (r.num, r.num2) OR (r.num2 ~ '^[0-9]{1,15}$' AND c.st_id = CASE WHEN r.num2 ~ '^[0-9]{1,15}$' THEN r.num2::bigint END))
                   AND (r.words IS NULL OR EXISTS (SELECT 1 FROM unnest(r.words) w WHERE position(w IN lower(c.display_name)) > 0))
                 ORDER BY (c.customer_number = r.num) DESC, c.merged_into_id IS NULL DESC, c.id LIMIT 1) AS id
    FROM r WHERE r.num IS NOT NULL),
  bylink AS MATERIALIZED (SELECT DISTINCT ON (r.i) r.i, k.customer_id AS id FROM r
              JOIN pap_links k ON k.name_key = coalesce(r.nm, '') AND k.ref_key = lower(coalesce(r.num, ''))
              ORDER BY r.i, k.set_at DESC),
  m AS MATERIALIZED (
    SELECT r.i, lk.id AS by_link, bn.id AS by_num, CASE WHEN a.n = 1 THEN a.id END AS by_addr, CASE WHEN p.n = 1 THEN p.id END AS by_phone, CASE WHEN b.n = 1 THEN b.id END AS by_name
    FROM r
    LEFT JOIN bylink lk ON lk.i = r.i
    LEFT JOIN bynum bn ON bn.i = r.i
    LEFT JOIN byaddr a ON a.i = r.i
    LEFT JOIN byphone p ON p.ph = r.ph
    LEFT JOIN byname b ON b.i = r.i)
  SELECT m.i, c.id, c.customer_number, c.display_name,
         CASE WHEN m.by_link IS NOT NULL THEN 'manual' WHEN m.by_num IS NOT NULL THEN 'number' WHEN m.by_addr IS NOT NULL THEN 'address' WHEN m.by_phone IS NOT NULL THEN 'phone' ELSE 'name' END,
         c.pap_list
  FROM m
  JOIN customers c0 ON c0.id = coalesce(m.by_link, m.by_num, m.by_addr, m.by_phone, m.by_name)
  JOIN customers c ON c.id = coalesce(c0.merged_into_id, c0.id);
END $$;

-- Link a row of the bank's file to a customer (p_customer NULL = forget the link)
CREATE OR REPLACE FUNCTION public.pap_link_set(p_ref text, p_name text, p_customer bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_name text := coalesce(nullif(btrim(regexp_replace(lower(replace(coalesce(p_name, ''), '&amp;', '&')), '\s+', ' ', 'g')), ''), '');
        v_ref text := lower(coalesce(nullif(regexp_replace(btrim(coalesce(p_ref, '')), '\.0+$', ''), ''), ''));
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RAISE EXCEPTION 'Only owners can do this'; END IF;
  IF v_name = '' AND v_ref = '' THEN RAISE EXCEPTION 'Nothing to link'; END IF;
  IF p_customer IS NULL THEN
    DELETE FROM pap_links WHERE name_key = v_name AND ref_key = v_ref;
  ELSE
    INSERT INTO pap_links (name_key, ref_key, customer_id, set_by) VALUES (v_name, v_ref, p_customer, public.current_app_user_id())
    ON CONFLICT (name_key, ref_key) DO UPDATE SET customer_id = EXCLUDED.customer_id, set_by = EXCLUDED.set_by, set_at = now();
  END IF;
  INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values)
  VALUES ('pap_links', coalesce(p_customer, 0), 'update', public.current_app_user_id(),
          jsonb_build_object('change', CASE WHEN p_customer IS NULL THEN 'EFT link removed' ELSE 'EFT row linked to customer' END, 'name', p_name, 'reference', p_ref));
END $$;

-- A customer's details for the panel under an EFT row
CREATE OR REPLACE FUNCTION public.pap_customer_card(p_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE
    (SELECT jsonb_build_object(
       'id', c.id, 'name', c.display_name, 'number', c.customer_number, 'status', to_jsonb(c) ->> 'status', 'pap_list', c.pap_list, 'pap_set_at', c.pap_set_at,
       'contacts', (SELECT coalesce(jsonb_agg(jsonb_build_object('kind', k.kind, 'value', k.value, 'primary', k.is_primary) ORDER BY k.is_primary DESC, k.id), '[]')
                    FROM customer_contacts k WHERE k.customer_id = c.id),
       'locations', (SELECT coalesce(jsonb_agg(jsonb_build_object('street', l.street, 'city', l.city, 'postal', coalesce(to_jsonb(l) ->> 'postal_code', to_jsonb(l) ->> 'zip'),
                       'active', l.active) ORDER BY l.active DESC, l.id), '[]') FROM locations l WHERE l.customer_id = c.id),
       'owing', (SELECT coalesce(sum(i.balance_due), 0) FROM invoices i WHERE i.customer_id = c.id AND i.status NOT IN ('void', 'draft') AND i.balance_due > 0.004),
       'invoices', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'number', x.invoice_number, 'date', x.invoice_date, 'total', x.total, 'balance', x.balance_due)
                       ORDER BY x.invoice_date DESC, x.id DESC), '[]')
                    FROM (SELECT * FROM invoices i WHERE i.customer_id = c.id AND i.status NOT IN ('void', 'draft') ORDER BY i.invoice_date DESC, i.id DESC LIMIT 5) x))
     FROM customers c WHERE c.id = p_id) END
$$;

REVOKE EXECUTE ON FUNCTION public.pap_link_set(text, text, bigint), public.pap_customer_card(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_link_set(text, text, bigint), public.pap_customer_card(bigint) TO authenticated;

-- 99zzz8_amount_more.sql
-- =====================================================================
-- Receivables, Find by amount: two more ways to look.
--   invoice_amount_near:  every invoice whose total, amount paid or balance owing is within p_range (default $100)
--                         above or below the amount, closest first.
--   invoice_amount_pairs: two invoices whose totals (or balances owing, or amounts paid) add up to exactly the amount;
--                         the same customer's pairs first, then the ones closest together in date.
-- Same people as Receivables. Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.invoice_amount_near(p_amount numeric, p_range numeric DEFAULT 100)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '30s' AS $$
  WITH a AS (SELECT round(p_amount, 2) AS v, least(greatest(abs(coalesce(p_range, 100)), 0.01), 10000) AS d),
  hit AS (
    SELECT i.id FROM invoices i, a WHERE i.total BETWEEN a.v - a.d AND a.v + a.d
    UNION SELECT i.id FROM invoices i, a WHERE i.balance_due BETWEEN a.v - a.d AND a.v + a.d AND i.balance_due > 0.004
    UNION SELECT i.id FROM invoices i, a WHERE i.amount_paid BETWEEN a.v - a.d AND a.v + a.d AND i.amount_paid > 0.004),
  p AS (
    SELECT i.*, least(abs(i.total - a.v), CASE WHEN i.balance_due > 0.004 THEN abs(i.balance_due - a.v) END,
                      CASE WHEN i.amount_paid > 0.004 THEN abs(i.amount_paid - a.v) END) AS diff
    FROM invoices i JOIN hit h ON h.id = i.id, a
    WHERE (public.has_permission('invoices.adjust') OR coalesce(public.current_staff_role() IN ('owner', 'admin', 'accounting'), false))
      AND p_amount IS NOT NULL AND i.status NOT IN ('void', 'draft'))
  SELECT jsonb_build_object(
    'amount', (SELECT v FROM a), 'range', (SELECT d FROM a),
    'n', (SELECT count(*) FROM p),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object(
               'invoice_id', x.id, 'invoice_number', x.invoice_number, 'invoice_date', x.invoice_date, 'status', x.status,
               'total', x.total, 'paid', x.amount_paid, 'balance', x.balance_due, 'diff', x.diff,
               'on_total', abs(x.total - (SELECT v FROM a)) = x.diff, 'on_paid', x.amount_paid > 0.004 AND abs(x.amount_paid - (SELECT v FROM a)) = x.diff,
               'on_balance', x.balance_due > 0.004 AND abs(x.balance_due - (SELECT v FROM a)) = x.diff,
               'customer_id', c.id, 'customer_name', c.display_name, 'customer_number', c.customer_number, 'street', l.street, 'city', l.city,
               'job_type', t.name) ORDER BY x.diff, x.invoice_date DESC, x.id DESC), '[]')
             FROM (SELECT * FROM p ORDER BY diff, invoice_date DESC, id DESC LIMIT 500) x
             JOIN customers c ON c.id = x.customer_id
             LEFT JOIN locations l ON l.id = x.location_id
             LEFT JOIN jobs j ON j.id = x.job_id
             LEFT JOIN job_types t ON t.id = j.job_type_id))
$$;

-- p_field: 'total' (the invoice totals), 'balance' (what's still owed) or 'paid' (what was paid on them)
CREATE OR REPLACE FUNCTION public.invoice_amount_pairs(p_amount numeric, p_field text DEFAULT 'total')
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '30s' AS $$
DECLARE v numeric := round(p_amount, 2); f text := CASE WHEN p_field IN ('total', 'balance', 'paid') THEN p_field ELSE 'total' END; r jsonb;
BEGIN
  IF NOT (public.has_permission('invoices.adjust') OR coalesce(public.current_staff_role() IN ('owner', 'admin', 'accounting'), false)) OR v IS NULL OR v <= 0 THEN
    RETURN jsonb_build_object('amount', v, 'field', f, 'n', 0, 'rows', '[]'::jsonb);
  END IF;
  WITH inv AS MATERIALIZED (
    SELECT i.id, i.customer_id, i.invoice_date, CASE f WHEN 'balance' THEN i.balance_due WHEN 'paid' THEN i.amount_paid ELSE i.total END AS amt
    FROM invoices i
    WHERE i.status NOT IN ('void', 'draft')
      AND CASE f WHEN 'balance' THEN i.balance_due WHEN 'paid' THEN i.amount_paid ELSE i.total END BETWEEN 0.01 AND v - 0.01),
  pr AS (
    SELECT a.id AS a_id, b.id AS b_id, (a.customer_id = b.customer_id) AS same, abs(a.invoice_date - b.invoice_date) AS gap
    FROM inv a JOIN inv b ON b.amt = v - a.amt AND (a.amt < b.amt OR (a.amt = b.amt AND a.id < b.id))
    LIMIT 20000),
  top AS (SELECT * FROM pr ORDER BY same DESC, gap NULLS LAST, a_id DESC LIMIT 200),
  one AS (
    SELECT x.id, jsonb_build_object('invoice_id', x.id, 'invoice_number', x.invoice_number, 'invoice_date', x.invoice_date, 'status', x.status,
             'total', x.total, 'paid', x.amount_paid, 'balance', x.balance_due,
             'customer_id', c.id, 'customer_name', c.display_name, 'customer_number', c.customer_number, 'street', l.street, 'city', l.city, 'job_type', t.name) AS j
    FROM invoices x JOIN customers c ON c.id = x.customer_id
    LEFT JOIN locations l ON l.id = x.location_id LEFT JOIN jobs jb ON jb.id = x.job_id LEFT JOIN job_types t ON t.id = jb.job_type_id
    WHERE x.id IN (SELECT a_id FROM top UNION SELECT b_id FROM top))
  SELECT jsonb_build_object('amount', v, 'field', f, 'n', (SELECT count(*) FROM pr), 'capped', (SELECT count(*) FROM pr) >= 20000,
           'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('same', t.same, 'gap', t.gap, 'a', oa.j, 'b', ob.j) ORDER BY t.same DESC, t.gap NULLS LAST, t.a_id DESC)
                             FROM top t JOIN one oa ON oa.id = t.a_id JOIN one ob ON ob.id = t.b_id), '[]'))
  INTO r;
  RETURN r;
END $$;

ALTER FUNCTION public.invoice_amount_near(numeric, numeric) SET jit = off;
ALTER FUNCTION public.invoice_amount_pairs(numeric, text) SET jit = off;
REVOKE EXECUTE ON FUNCTION public.invoice_amount_near(numeric, numeric), public.invoice_amount_pairs(numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invoice_amount_near(numeric, numeric), public.invoice_amount_pairs(numeric, text) TO authenticated;

-- 99zzz9_security_flags.sql
-- =====================================================================
-- Security page: which customers have a security account, for the badges in the EFT customer search and panel.
--   monitoring = they have invoices in the "Security Monitoring" department
--   security   = they've had any security work (Security departments, or a security job type)
-- Also when their last security invoice was, and their PAP list. Owners only. Safe to run more than once.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.pap_security_flags(p_ids bigint[])
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH ids AS (SELECT DISTINCT unnest(p_ids[1:200]) AS id),
  bu AS (SELECT id, name ILIKE '%monitor%' AS mon FROM business_units WHERE name ILIKE '%secur%'),
  inv AS (SELECT i.customer_id, bool_or(bu.mon) AS mon, max(i.invoice_date) AS last, max(i.invoice_date) FILTER (WHERE bu.mon) AS last_mon
          FROM invoices i JOIN bu ON bu.id = i.business_unit_id
          WHERE i.customer_id IN (SELECT id FROM ids) AND i.status NOT IN ('void', 'draft') GROUP BY i.customer_id),
  jb AS (SELECT DISTINCT j.customer_id FROM jobs j JOIN job_types t ON t.id = j.job_type_id
         WHERE j.customer_id IN (SELECT id FROM ids) AND (t.job_class = 'security' OR t.name ILIKE '%secur%' OR t.name ILIKE '%alarm%'))
  SELECT CASE WHEN NOT coalesce(public._is_owner(), false) THEN NULL ELSE
    coalesce(jsonb_object_agg(c.id, jsonb_build_object(
      'monitoring', coalesce(inv.mon, false), 'security', inv.customer_id IS NOT NULL OR jb.customer_id IS NOT NULL,
      'last', inv.last, 'last_monitoring', inv.last_mon, 'pap_list', c.pap_list)), '{}') END
  FROM ids JOIN customers c ON c.id = ids.id
  LEFT JOIN inv ON inv.customer_id = c.id LEFT JOIN jb ON jb.customer_id = c.id
$$;
REVOKE EXECUTE ON FUNCTION public.pap_security_flags(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pap_security_flags(bigint[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
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
        cur.execute("SELECT to_regprocedure('public.set_pb_item_look(bigint,jsonb,numeric)') IS NOT NULL AND to_regprocedure('public.set_pb_item_labour(bigint,numeric,integer,numeric)') IS NOT NULL AND to_regprocedure('public.set_tech_kind(bigint,text)') IS NOT NULL AND to_regprocedure('public.set_job_partner(bigint,bigint)') IS NOT NULL AND to_regprocedure('public.est_close(bigint,bigint)') IS NOT NULL AND to_regprocedure('public._can_see_invoices()') IS NOT NULL AND to_regprocedure('public.set_golive_lock(boolean)') IS NOT NULL AND to_regprocedure('public._is_install_sale(text)') IS NOT NULL AND to_regprocedure('public.sales_list(bigint)') IS NOT NULL AND to_regprocedure('public.set_job_seller(bigint,bigint)') IS NOT NULL AND to_regprocedure('public.est_cancel(bigint)') IS NOT NULL AND to_regprocedure('public.sales_on_site(bigint)') IS NOT NULL AND to_regprocedure('public.set_sales_for(bigint,bigint[])') IS NOT NULL AND to_regprocedure('public._sales_own_visit(bigint)') IS NOT NULL AND to_regprocedure('public.sales_job_cancel(bigint)') IS NOT NULL AND to_regprocedure('public.est_item_info(bigint[])') IS NOT NULL AND to_regprocedure('public.est_costing(bigint[])') IS NOT NULL AND to_regprocedure('public.copy_addon_kit(bigint,text)') IS NOT NULL AND to_regprocedure('public.delete_addon_kit(bigint)') IS NOT NULL AND to_regprocedure('public.pap_set(bigint[],text,boolean)') IS NOT NULL AND to_regprocedure('public.htin_book_link(bigint,bigint)') IS NOT NULL AND to_regprocedure('public.partner_booking_edit(bigint,jsonb)') IS NOT NULL AND to_regprocedure('public.partner_booking_details_import(bigint,jsonb)') IS NOT NULL AND to_regprocedure('public.partner_bookings_export(bigint)') IS NOT NULL AND to_regprocedure('public.customer_partner_bookings(bigint)') IS NOT NULL AND to_regprocedure('public.set_job_tank_payer(bigint,text)') IS NOT NULL")
        if os.environ.get("GITHUB_ACTIONS"): print(f"::notice::Item looks ready in the database: {cur.fetchone()[0]}", flush=True)
    except Exception as e:
        conn.rollback(); log(f"  App database pieces not added: {str(e)[:200]}")
        if os.environ.get("GITHUB_ACTIONS"): print(f"::notice::Item looks not added: {str(e)[:200]}", flush=True)
    for attempt in range(3):   # after APP_SCHEMA, so these newer versions win; a busy app can deadlock these changes for a moment: try again
        try:
            cur.execute(EXTRA_SCHEMA); conn.commit(); log("Extra database pieces checked (find by amount, EFT people)."); break
        except Exception as e:
            conn.rollback(); log(f"  Extra database pieces not added (try {attempt + 1}): {str(e)[:200]}")
            if os.environ.get("GITHUB_ACTIONS") and attempt == 2: print(f"::notice::Find by amount not added: {str(e)[:200]}", flush=True)
            time.sleep(5)

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
                    cur.execute("SELECT coalesce(string_agg(y || ': ' || n, ', ' ORDER BY y), 'none') FROM (SELECT extract(year FROM created_at)::int y, count(*) n FROM purchase_orders GROUP BY 1) t")
                    print(f"::notice::Purchase orders by the date the POs page uses: {cur.fetchone()[0]}", flush=True)
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

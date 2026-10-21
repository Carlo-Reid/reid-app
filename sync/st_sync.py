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

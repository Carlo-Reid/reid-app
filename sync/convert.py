"""
Convert the ServiceTitan export (CSV files) into load files for the new database.

Usage: python convert.py <export_dir> <out_dir>

Nightly sync ("delta") mode: set ST_DELTA_KNOWN to a JSON file describing what's already in the database
(ids, lookup lists). Only the changed records in <export_dir> are converted; settings tables and the
pricebook are left alone, and new lookup rows (job types, brands, equipment types) continue the numbering.

Every migrated record keeps its ServiceTitan id as its new id (and in st_id),
so links between records carry straight over and old numbers stay searchable.
Output: one CSV per target table, NULL written as \\N, plus manifest.json
(load order + column lists) and report.json (counts and anything skipped).
"""
import csv, json, os, re, sys, html
from collections import Counter, defaultdict
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

csv.field_size_limit(10**9)
TZ = ZoneInfo("America/Toronto")
SRC, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
NULL = "\\N"
NOW_ISO = datetime.now(timezone.utc).isoformat()
report = {"counts": {}, "skipped": Counter(), "notes": []}
DELTA = None
if os.environ.get("ST_DELTA_KNOWN"):
    DELTA = json.load(open(os.environ["ST_DELTA_KNOWN"], encoding="utf-8"))
def known(key, kind=set):
    v = (DELTA or {}).get(key)
    if v is None: return kind()
    if kind is set: return set(v)
    return v

# ---------------------------------------------------------------------------
# Business unit mapping (old ServiceTitan unit -> new unit, optional partner)
# ---------------------------------------------------------------------------
NEW_UNITS = ["Partners", "HVAC Service", "HVAC Sales", "Duct Cleaning", "Maintenance & Plans",
             "Security Equipment", "Security Service", "Security Cameras", "Security Monitoring",
             "Carpet Cleaning"]
INACTIVE_UNITS = {"Carpet Cleaning"}
BU_MAP = {   # st business unit id -> (new unit, partner name or None)
    2564: ("HVAC Service", None), 1282: ("HVAC Service", None),
    2562: ("HVAC Sales", None), 2565: ("Duct Cleaning", None),
    11899003: ("Maintenance & Plans", None),
    2563: ("Partners", "Vista Credit"), 25947306: ("Partners", "Vista Credit"),
    82611507: ("Partners", "Costco"), 36099555: ("Partners", "Rona"),
    2578: ("Security Equipment", None), 2580: ("Security Service", None),
    2581: ("Security Cameras", None), 11896061: ("Security Monitoring", None),
    1425197: ("Maintenance & Plans", None), 1425196: ("Maintenance & Plans", None),
    1425195: ("HVAC Service", None), 1425208: ("HVAC Service", None), 1425192: ("HVAC Service", None),
    1425193: ("HVAC Sales", None), 1425194: ("HVAC Sales", None),
    1425201: ("HVAC Sales", None), 1425199: ("HVAC Sales", None),
    1425200: ("Duct Cleaning", None),
    1425198: ("Security Service", None), 1425210: ("Security Service", None),
    1425206: ("Partners", "Vista Credit"), 1425204: ("Partners", "Rona"),
    1425203: ("Partners", "Lennox"), 1425202: ("Partners", "Maytag"),
    1425211: ("Partners", "York"), 1425205: ("Partners", "IWS"),
    1425212: ("Partners", None),
    1425207: ("Carpet Cleaning", None),
    1425213: ("Partners", "Lowe's"), 1425209: ("Partners", None),
}
IMPORTED_DEFAULT_BU = {114725, 10972487}   # sorted by job type instead
PARTNERS = {  # name -> partner type
    "Costco": "Retailer", "Rona": "Retailer", "Lowe's": "Retailer", "Vista Credit": "Rental company",
    "Lennox": "Manufacturer", "Maytag": "Manufacturer", "York": "Manufacturer", "IWS": "Manufacturer",
}
PARTNER_IDS = {name: i + 1 for i, name in enumerate(PARTNERS)}   # loader seeds partners with these ids

def unit_from_job_type(name):
    n = (name or "").lower()
    if any(k in n for k in ("carpet",)): return "Carpet Cleaning"
    if any(k in n for k in ("duct",)): return "Duct Cleaning"
    if any(k in n for k in ("security", "alarm", "camera", "monitor")): return "Security Service"
    if any(k in n for k in ("clean", "c & c", "c&c", "maint", "tune", "inspection", "plan")): return "Maintenance & Plans"
    if any(k in n for k in ("install", "quote", "sale", "estimate", "replace", "walk s")): return "HVAC Sales"
    return "HVAC Service"
UNIT_IDS = {u: i + 1 for i, u in enumerate(NEW_UNITS)}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def rows(name):
    path = os.path.join(SRC, name)
    if DELTA is not None and not os.path.exists(path):
        return
    with open(path, encoding="utf-8-sig", newline="") as fh:
        for r in csv.DictReader(fh):
            yield _Row(r)

class _Row(dict):
    """A CSV row where a column ServiceTitan didn't send reads as empty text."""
    def __missing__(self, key): return ""

def j(s, default=None):
    if s is None or s == "": return default
    if isinstance(s, (dict, list)): return s
    try: return json.loads(s)
    except Exception: return default

def num(s, default=None):
    if s is None or s == "": return default
    try: return round(float(s), 2)
    except Exception: return default

def intval(s):
    if s in (None, ""): return None
    try: return int(float(s))
    except Exception: return None

def ts(s):
    """ISO UTC text -> ISO text (keeps tz). Drops ServiceTitan's 0001-01-01 placeholder."""
    if not s or s.startswith("0001-"): return None
    return s

def local_date(s):
    if not s or s.startswith("0001-"): return None
    d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    return d.astimezone(TZ).date().isoformat()

def date_only(s):
    if not s or s.startswith("0001-"): return None
    return s[:10]

def clean_text(s, limit=None):
    if s is None: return None
    s = html.unescape(re.sub(r"<[^>]+>", " ", s)).replace("\r\n", "\n").replace("\r", "\n")
    s = re.sub(r"[ \t]+", " ", s).strip()
    if limit: s = s[:limit]
    return s or None

def b(v): return "true" if v in (True, "true", "True", "1", 1) else "false"

class Writer:
    order = []
    def __init__(self, table, columns):
        self.table, self.columns, self.n = table, columns, 0
        self.fh = open(os.path.join(OUT, f"{table}.csv"), "w", encoding="utf-8", newline="")
        self.w = csv.writer(self.fh)
        self.w.writerow(columns)
        Writer.order.append(self)
    def add(self, **kw):
        out = []
        for c in self.columns:
            v = kw.get(c)
            if v is None and c == "created_at": v = NOW_ISO   # column is NOT NULL
            out.append(NULL if v is None else v)
        self.w.writerow(out); self.n += 1
    def close(self):
        self.fh.close(); report["counts"][self.table] = self.n

# ---------------------------------------------------------------------------
# 1. Settings rows: business units, partners, suppliers, manufacturers
# ---------------------------------------------------------------------------
if DELTA is None:
  w = Writer("business_units", ["id", "name", "trade", "sort_order", "active"])
  for u, i in UNIT_IDS.items():
    w.add(id=i, name=u, trade="Security" if u.startswith("Security") else "HVAC", sort_order=i,
          active=b(u not in INACTIVE_UNITS))
  w.close()

st_bu_names = {}
for r in rows("business-units.csv"):
    st_bu_names[int(r["id"])] = r["name"]
if DELTA is None:
  w = Writer("business_unit_migration_map", ["st_business_unit_id", "st_name", "business_unit_id", "partner_name"])
  for st, (u, p) in BU_MAP.items():
    w.add(st_business_unit_id=st, st_name=st_bu_names.get(st, f"ServiceTitan unit {st}"),
          business_unit_id=UNIT_IDS[u], partner_name=p)
  w.close()

PARTNER_TYPE_IDS = {"Retailer": 1, "Rental company": 2, "Insurance company": 3, "General contractor": 4,
                    "HVAC company": 5, "Manufacturer": 6}   # order seeded by schema_core.sql
w = Writer("partners", ["id", "partner_type_id", "name", "customer_pays_partner", "collect_payment_on_site",
                        "requires_authorization", "requires_partner_reference", "payment_terms_days"])
for name, ptype in (PARTNERS.items() if DELTA is None else []):
    retail = ptype == "Retailer"
    w.add(id=PARTNER_IDS[name], partner_type_id=PARTNER_TYPE_IDS[ptype], name=name, customer_pays_partner=b(retail),
          collect_payment_on_site=b(ptype not in ("Retailer", "Rental company")),
          requires_authorization=b(name == "Vista Credit"), requires_partner_reference=b(retail),
          payment_terms_days=30)
w.close()

# suppliers from pricebook vendor names
suppliers = dict(known("suppliers", dict))
NEW_SUPPLIERS = set()
def supplier_id(name):
    if not name or name.lower().startswith("default replenishment"): return None
    if name not in suppliers:
        suppliers[name] = max(suppliers.values(), default=0) + 1; NEW_SUPPLIERS.add(name)
    return suppliers[name]

manufacturers = {k: tuple(v) for k, v in known("manufacturers", dict).items()}   # UPPER name -> (id, name)
NEW_MANUFACTURERS = set()
def manufacturer_id(name):
    name = (name or "").strip()
    if not name: return None
    key = name.upper()
    if key not in manufacturers:
        manufacturers[key] = (max((v[0] for v in manufacturers.values()), default=0) + 1, nice_name(name)); NEW_MANUFACTURERS.add(key)
    return manufacturers[key][0]

equipment_types = {k: tuple(v) for k, v in known("equipment_types", dict).items()}
NEW_EQUIPMENT_TYPES = set()
ACRONYMS = {"ERV", "ICP", "AUB", "IBC", "ADP", "IAQ", "HIK", "UPS", "USA", "AFUE", "SEER", "HEPA", "HVAC", "LED"}
def nice_name(name):
    """Title-case SHOUTED words, but keep codes and acronyms (ERV, HRV, HWT, DSC, A/C, SLP99UH) in capitals."""
    if not name.isupper(): return name
    def word(w):
        if len(w) <= 2 or any(ch.isdigit() for ch in w) or not w.isalpha() or w in ACRONYMS: return w
        if not any(v in w for v in "AEIOUY"): return w          # HRV, HWT, NVR, DSC, BBQ
        return w.title()
    return " ".join(word(w) for w in name.split(" "))

def equipment_type_id(name):
    name = (name or "").strip() or "Unknown"
    key = name.upper()
    if key not in equipment_types:
        equipment_types[key] = (max((v[0] for v in equipment_types.values()), default=0) + 1, nice_name(name)); NEW_EQUIPMENT_TYPES.add(key)
    return equipment_types[key][0]

# ---------------------------------------------------------------------------
# 2. Employees (technicians + office staff)
# ---------------------------------------------------------------------------
w = Writer("employees", ["id", "first_name", "last_name", "email", "mobile_phone", "job_title", "is_technician",
                         "hourly_wage", "burden_pct", "active", "hired_on", "st_id"])
tech_users = set()
def split_name(r):
    fn, ln = (r.get("firstName") or "").strip(), (r.get("lastName") or "").strip()
    if not fn and not ln:
        parts = (r.get("name") or "Unknown").strip().split(" ", 1)
        fn, ln = parts[0], parts[1] if len(parts) > 1 else ""
    return fn or "Unknown", ln
employee_ids = known("employee_ids")
for r in rows("technicians.csv"):
    fn, ln = split_name(r)
    tech_users.add(r["userId"])
    w.add(id=r["id"], first_name=fn, last_name=ln, email=r["email"] or None,
          mobile_phone=r["mobilePhone"] or r["phoneNumber"] or None, job_title="Technician", is_technician="true",
          hourly_wage=num(r["hourlyRate"]), burden_pct=num(r["burdenRate"], 0), active=b(r["active"]),
          hired_on=date_only(r["startDate"]), st_id=r["id"])
    employee_ids.add(int(r["id"]))
for r in rows("employees.csv"):
    if r["userId"] and r["userId"] in tech_users: continue
    fn, ln = split_name(r)
    w.add(id=r["id"], first_name=fn, last_name=ln, email=r["email"] or None, mobile_phone=r["phoneNumber"] or None,
          job_title=r["role"] or None, is_technician="false", hourly_wage=num(r["hourlyRate"]), burden_pct=0,
          active=b(r["active"]), hired_on=date_only(r["startDate"]), st_id=r["id"])
    employee_ids.add(int(r["id"]))
w.close()

# ---------------------------------------------------------------------------
# 3. Customers, locations, contacts
# ---------------------------------------------------------------------------
customer_ids = known("customer_ids")
flags = []
w = Writer("customers", ["id", "customer_number", "customer_type", "display_name", "company_name", "status",
                         "marketing_opt_in", "notes", "st_id", "created_at"])
for r in rows("customers.csv"):
    name = re.sub(r"\s+", " ", html.unescape(r["name"] or "")).strip() or f"Customer {r['id']}"
    ctype = "commercial" if r["type"] == "Commercial" else "residential"
    notes = f"Merged into customer {r['mergedToId']} in ServiceTitan" if r["mergedToId"] else None
    w.add(id=r["id"], customer_number=r["id"], customer_type=ctype, display_name=name,
          company_name=name if ctype == "commercial" else None,
          status="active" if r["active"] == "true" and not r["mergedToId"] else "inactive",
          marketing_opt_in=b(r["doNotMail"] != "true"), notes=notes, st_id=r["id"], created_at=ts(r["createdOn"]))
    customer_ids.add(int(r["id"]))
    if r["doNotService"] == "true":
        flags.append((int(r["id"]), "do_not_service", "Marked Do Not Service in ServiceTitan"))
w.close()

w = Writer("customer_flags", ["customer_id", "flag_type", "message"])
for cid, ft, msg in flags: w.add(customer_id=cid, flag_type=ft, message=msg)
w.close()

location_ids = known("location_ids")
location_customer = {int(k): v for k, v in known("location_customer", dict).items()}
w = Writer("locations", ["id", "customer_id", "name", "street", "unit", "city", "province", "postal_code", "country",
                         "latitude", "longitude", "active", "st_id", "created_at"])
for r in rows("locations.csv"):
    cid = int(r["customerId"]) if r["customerId"] else None
    if cid not in customer_ids:
        report["skipped"]["location_without_customer"] += 1; continue
    a = j(r["address"], {}) or {}
    country = (a.get("country") or "CA").strip()
    country = {"Canada": "CA", "United States": "US", "USA": "US"}.get(country, country[:2].upper() or "CA")
    w.add(id=r["id"], customer_id=cid, name=clean_text(r["name"]), street=(a.get("street") or "").strip(),
          unit=a.get("unit") or None, city=(a.get("city") or "").strip(), province=(a.get("state") or "ON")[:20],
          postal_code=a.get("zip") or None, country=country, latitude=a.get("latitude"), longitude=a.get("longitude"),
          active=b(r["active"] == "true" and not r["mergedToId"]), st_id=r["id"], created_at=ts(r["createdOn"]))
    location_ids.add(int(r["id"])); location_customer[int(r["id"])] = cid
w.close()

KIND = {"Phone": "phone", "MobilePhone": "mobile", "Email": "email", "Fax": "fax"}
w = Writer("customer_contacts", ["customer_id", "location_id", "contact_name", "kind", "value", "allow_sms",
                                 "allow_marketing_email", "st_id"])
for r in rows("customer-contacts.csv"):
    cid = intval(r["customerId"])
    if cid not in customer_ids or not r["value"] or r["type"] not in KIND or r["active"] != "true":
        report["skipped"]["customer_contact"] += 1; continue
    ps, pref = j(r["phoneSettings"], {}) or {}, j(r["preferences"], {}) or {}
    w.add(customer_id=cid, location_id=None, contact_name=clean_text(r["memo"], 100), kind=KIND[r["type"]],
          value=r["value"].strip(), allow_sms=b(not ps.get("doNotText", False)),
          allow_marketing_email=b(pref.get("marketingUpdatesEnabled", True)), st_id=r["id"])
for r in rows("location-contacts.csv"):
    lid = intval(r["locationId"])
    if lid not in location_ids or not r["value"] or r["type"] not in KIND or r["active"] != "true":
        report["skipped"]["location_contact"] += 1; continue
    ps, pref = j(r["phoneSettings"], {}) or {}, j(r["preferences"], {}) or {}
    w.add(customer_id=location_customer[lid], location_id=lid, contact_name=clean_text(r["memo"], 100),
          kind=KIND[r["type"]], value=r["value"].strip(), allow_sms=b(not ps.get("doNotText", False)),
          allow_marketing_email=b(pref.get("marketingUpdatesEnabled", True)), st_id=r["id"])
w.close()

# ---------------------------------------------------------------------------
# 4. Job types (names recovered from invoices for retired types)
# ---------------------------------------------------------------------------
jt_names = {int(k): tuple(v) for k, v in known("job_types", dict).items()}
for r in rows("job-types.csv"):
    jt_names[int(r["id"])] = (r["name"].strip(), r["active"] == "true", intval(r["duration"]))
job_type_of_job = {int(k): v for k, v in known("job_type_of_job", dict).items()}
jobs_raw = list(rows("jobs.csv"))
for r in jobs_raw: job_type_of_job[int(r["id"])] = intval(r["jobTypeId"])
for r in rows("invoices.csv"):
    jb = j(r["job"]) or {}
    t = job_type_of_job.get(jb.get("id"))
    if t and t not in jt_names and jb.get("type"):
        jt_names[t] = (html.unescape(jb["type"]).strip(), False, None)
used_types = Counter(job_type_of_job.values())
def job_class(name):
    n = name.lower()
    if "duct" in n: return "duct_cleaning"
    if "warranty" in n: return "warranty"
    if any(k in n for k in ("security", "alarm", "camera")): return "security"
    if any(k in n for k in ("maint", "clean", "c & c", "tune")): return "maintenance"
    if "install" in n: return "install"
    if any(k in n for k in ("quote", "sale", "walk s")): return "sales"
    return "service"
w = Writer("job_types", ["id", "name", "job_class", "default_duration_minutes", "active", "st_id"])
seen_names = Counter()
job_type_name = {}
for t in sorted(set(used_types) | set(jt_names)):
    if t is None: continue
    name, active, dur = jt_names.get(t, (f"Imported job type {t}", False, None))
    if t == 114722: name, active = "Imported job (no type)", False
    seen_names[name.lower()] += 1
    if seen_names[name.lower()] > 1: name = f"{name} ({t})"
    job_type_name[t] = name
    w.add(id=t, name=name, job_class=job_class(name), default_duration_minutes=(dur // 60 if dur and dur > 300 else dur) or 60,
          active=b(active), st_id=t)
w.close()

def unit_for(st_bu, job_type=None):
    if st_bu in BU_MAP: return BU_MAP[st_bu]
    if st_bu in IMPORTED_DEFAULT_BU or st_bu is None:
        return (unit_from_job_type(job_type_name.get(job_type, "")), None)
    report["skipped"]["unknown_business_unit_defaulted"] += 1
    return ("HVAC Service", None)

# ---------------------------------------------------------------------------
# 5. Pricebook
# ---------------------------------------------------------------------------
pb_id = {(t, int(st)): nid for t, st, nid in known("pricebook", list)}           # (type, st id) -> new id
pb_rows, kits = [], []
next_pb = 1
for fname, itype in ((("pricebook-services.csv", "service"), ("pricebook-materials.csv", "material"),
                      ("pricebook-equipment.csv", "equipment")) if DELTA is None else ()):
    for r in rows(fname):
        pv = j(r.get("primaryVendor"), {}) or {}
        cost = num(r.get("cost"), 0) or num(pv.get("cost"), 0) or 0
        mw = j(r.get("manufacturerWarranty"), {}) or {}
        new_id = next_pb; next_pb += 1
        pb_id[(itype, int(r["id"]))] = new_id
        pb_rows.append(dict(id=new_id, item_type=itype, sku=(r["code"] or f"ST-{r['id']}").strip(),
                            name=clean_text(r["displayName"], 300) or clean_text(r["code"]) or f"Item {r['id']}",
                            description=clean_text(r.get("description"), 4000), unit_of_measure=r.get("unitOfMeasure") or "each",
                            unit_cost=cost, unit_price=num(r.get("price"), 0), taxable=b(r.get("taxable")),
                            est_labour_hours=num(r.get("hours")), track_inventory=b(r.get("isInventory")),
                            preferred_supplier_id=supplier_id(pv.get("vendorName")),
                            manufacturer_id=manufacturer_id(r.get("manufacturer")) if itype == "equipment" else None,
                            model_number=r.get("model") or None,
                            mfr_parts_warranty_months=mw.get("duration") or None if itype == "equipment" else None,
                            active=b(r.get("active")), st_id=r["id"]))
        for comp in (j(r.get("equipmentMaterials"), []) or []) + (j(r.get("serviceMaterials"), []) or []):
            kits.append((new_id, comp.get("skuId"), num(comp.get("quantity"), 1)))
material_by_st = {st: nid for (t, st), nid in pb_id.items()}
sku_seen = Counter()
if DELTA is None:
 w = Writer("pricebook_items", ["id", "item_type", "sku", "name", "description", "unit_of_measure", "unit_cost",
                               "unit_price", "taxable", "est_labour_hours", "track_inventory", "preferred_supplier_id",
                                "manufacturer_id", "model_number", "mfr_parts_warranty_months", "active", "st_id"])
 for p in pb_rows:
     sku_seen[p["sku"].lower()] += 1
     if sku_seen[p["sku"].lower()] > 1: p["sku"] = f"{p['sku']}-{p['st_id']}"
     w.add(**p)
 w.close()
 w = Writer("pricebook_kit_items", ["parent_item_id", "component_item_id", "quantity"])
 seen = set()
 for parent, comp, qty in kits:
     cid = material_by_st.get(comp)
     if not cid or cid == parent or (parent, cid) in seen: continue
     seen.add((parent, cid)); w.add(parent_item_id=parent, component_item_id=cid, quantity=qty if qty and qty > 0 else 1)
 w.close()
pb_any = {}                                     # ServiceTitan id -> item, whatever its type here
for (t_, st_), nid_ in pb_id.items(): pb_any.setdefault(st_, nid_)
def pb_lookup(stype, sku_id):
    # items moved to another type in the app (e.g. Materials -> Parts or Security) are still found by their ServiceTitan id
    t = {"Service": "service", "Material": "material", "Equipment": "equipment"}.get(stype)
    return (pb_id.get((t, sku_id)) if t else None) or pb_any.get(sku_id)

# ---------------------------------------------------------------------------
# 6. Projects
# ---------------------------------------------------------------------------
project_ids = known("project_ids")
w = Writer("projects", ["id", "project_number", "name", "customer_id", "location_id", "status", "st_id", "created_at"])
pn = Counter()
for r in rows("projects.csv"):
    cid, lid = intval(r["customerId"]), intval(r["locationId"])
    if cid not in customer_ids or lid not in location_ids:
        report["skipped"]["project"] += 1; continue
    num_ = (r["number"] or r["id"]).strip(); pn[num_] += 1
    if pn[num_] > 1: num_ = f"{num_}-{r['id']}"
    st = (r["status"] or "").lower()
    status = "complete" if "complet" in st else "cancelled" if "cancel" in st else "in_progress"
    w.add(id=r["id"], project_number=num_, name=clean_text(r["name"]) or num_, customer_id=cid, location_id=lid,
          status=status, st_id=r["id"], created_at=ts(r["createdOn"]))
    project_ids.add(int(r["id"]))
w.close()

# ---------------------------------------------------------------------------
# 7. Jobs, visits, technicians on visits
# ---------------------------------------------------------------------------
JOB_STATUS = {"Completed": "completed", "Canceled": "cancelled", "InProgress": "in_progress",
              "Scheduled": "scheduled", "Hold": "on_hold"}
PRIORITY = {"Normal": "normal", "High": "high", "Urgent": "emergency", "Low": "normal"}
job_ids, job_unit, sold_from = known("job_ids"), {}, []
w = Writer("jobs", ["id", "job_number", "customer_id", "location_id", "job_type_id", "business_unit_id", "status",
                    "hold_reason", "priority", "summary", "description", "project_id", "partner_id", "po_number",
                    "sold_by_employee_id", "completed_at", "st_id", "created_at"])
for r in jobs_raw:
    cid, lid = intval(r["customerId"]), intval(r["locationId"])
    if cid not in customer_ids or lid not in location_ids:
        report["skipped"]["job_without_customer_or_location"] += 1; continue
    jt = intval(r["jobTypeId"])
    unit, partner = unit_for(intval(r["businessUnitId"]), jt)
    status = JOB_STATUS.get(r["jobStatus"], "completed")
    summary = clean_text(r["summary"], 2000) or job_type_name.get(jt) or "Imported job"
    sold = intval(r["soldById"])
    w.add(id=r["id"], job_number=r["jobNumber"], customer_id=cid, location_id=lid, job_type_id=jt,
          business_unit_id=UNIT_IDS[unit], status=status, hold_reason="other" if status == "on_hold" else None,
          priority=PRIORITY.get(r["priority"], "normal"), summary=summary.split("\n")[0][:300],
          description=summary if "\n" in summary or len(summary) > 300 else None,
          project_id=intval(r["projectId"]) if intval(r["projectId"]) in project_ids else None,
          partner_id=PARTNER_IDS.get(partner) if partner else None, po_number=r["customerPo"] or None,
          sold_by_employee_id=sold if sold in employee_ids else None, completed_at=ts(r["completedOn"]),
          st_id=r["id"], created_at=ts(r["createdOn"]))
    jid = int(r["id"]); job_ids.add(jid); job_unit[jid] = UNIT_IDS[unit]
    if intval(r["createdFromEstimateId"]): sold_from.append((jid, intval(r["createdFromEstimateId"])))
w.close()
del jobs_raw

VISIT_STATUS = {"Done": "completed", "Canceled": "cancelled", "Scheduled": "scheduled", "Hold": "scheduled",
                "Working": "on_site", "Dispatched": "dispatched"}
visit_ids = known("visit_ids"); visit_num = defaultdict(int); used_num = defaultdict(set)
existing_visit_num = {}
for jid_, m_ in known("visit_nums", dict).items():
    for vid_, n_ in m_.items():
        used_num[int(jid_)].add(n_); existing_visit_num[int(vid_)] = n_
w = Writer("visits", ["id", "job_id", "visit_number", "scheduled_date", "arrival_start", "arrival_end",
                      "est_duration_minutes", "status", "outcome_notes", "completed_at", "st_id", "created_at"])
for r in rows("appointments.csv"):
    jid = intval(r["jobId"])
    if jid not in job_ids:
        report["skipped"]["visit_without_job"] += 1; continue
    m = re.search(r"-(\d+)$", r["appointmentNumber"] or "")
    n = int(m.group(1)) if m else None
    if int(r["id"]) in existing_visit_num:
        n = existing_visit_num[int(r["id"])]
    elif n is None or n in used_num[jid]:
        n = max(used_num[jid] | {0}) + 1
    used_num[jid].add(n)
    start, end = ts(r["arrivalWindowStart"]) or ts(r["start"]), ts(r["arrivalWindowEnd"]) or ts(r["end"])
    dur = None
    if ts(r["start"]) and ts(r["end"]):
        dur = int((datetime.fromisoformat(r["end"].replace("Z", "+00:00")) -
                   datetime.fromisoformat(r["start"].replace("Z", "+00:00"))).total_seconds() // 60)
        dur = dur if 0 < dur < 100000 else None
    if start and end and end < start: end = start
    status = VISIT_STATUS.get(r["status"], "completed")
    w.add(id=r["id"], job_id=jid, visit_number=n, scheduled_date=local_date(start), arrival_start=start,
          arrival_end=end, est_duration_minutes=dur, status=status,
          outcome_notes=clean_text(r["specialInstructions"], 2000),
          completed_at=ts(r["end"]) if status == "completed" else None, st_id=r["id"], created_at=ts(r["createdOn"]))
    visit_ids.add(int(r["id"]))
w.close()

w = Writer("visit_assignments", ["visit_id", "employee_id", "role", "st_id"])
seen = set(); first_on_visit = known("visits_with_tech")
for r in sorted(rows("appointment-assignments.csv"), key=lambda r: (r["appointmentId"], r["assignedOn"])):
    vid, eid = intval(r["appointmentId"]), intval(r["technicianId"])
    if vid not in visit_ids or eid not in employee_ids or r["active"] != "true" or (vid, eid) in seen:
        report["skipped"]["visit_assignment"] += 1; continue
    seen.add((vid, eid))
    role = "lead" if vid not in first_on_visit else "helper"; first_on_visit.add(vid)
    w.add(visit_id=vid, employee_id=eid, role=role, st_id=r["id"])
w.close()

# ---------------------------------------------------------------------------
# 8. Plans (membership types + memberships)
# ---------------------------------------------------------------------------
plan_type_ids = known("plan_type_ids")
w = Writer("plan_types", ["id", "name", "plan_category", "visits_per_year", "repair_discount_pct", "monthly_price",
                          "yearly_price", "active", "st_id"])
pt_names = Counter()
for r in rows("membership-types.csv"):
    name = clean_text(r["displayName"] or r["name"], 200) or f"Plan {r['id']}"
    pt_names[name.lower()] += 1
    if pt_names[name.lower()] > 1: name = f"{name} ({r['id']})"
    db = j(r["durationBilling"], []) or []
    monthly = next((num(x.get("billingPrice")) for x in db if x and x.get("billingFrequency") == "Monthly"), None)
    yearly = next((num(x.get("billingPrice")) for x in db if x and x.get("billingFrequency") in ("Annual", "Yearly")), None)
    visits = len(j(r["recurringServices"], []) or [])
    n = name.lower()
    cat = "cleaning_only" if "clean" in n and "warrant" not in n else "warranty_maintenance" if "warrant" in n else "other"
    disc = num(r["discount"], 0) or 0
    w.add(id=r["id"], name=name, plan_category=cat, visits_per_year=visits, repair_discount_pct=min(disc, 100),
          monthly_price=monthly, yearly_price=yearly, active=b(r["active"]), st_id=r["id"])
    plan_type_ids.add(int(r["id"]))
w.close()

MEM_STATUS = {"Active": "active", "Canceled": "cancelled", "Expired": "expired", "Suspended": "suspended"}
FREQ = {"Annual": "yearly", "Monthly": "monthly"}
w = Writer("memberships", ["id", "membership_number", "customer_id", "location_id", "plan_type_id", "status",
                           "start_date", "end_date", "billing_frequency", "sold_by_employee_id", "cancelled_on", "st_id"])
for r in rows("memberships.csv"):
    if r["status"] == "Deleted":
        report["skipped"]["membership_deleted_in_servicetitan"] += 1; continue
    cid, lid, pt = intval(r["customerId"]), intval(r["locationId"]), intval(r["membershipTypeId"])
    if cid not in customer_ids or pt not in plan_type_ids:
        report["skipped"]["membership_missing_link"] += 1; continue
    if lid not in location_ids:
        lid = next((l for l, c in location_customer.items() if c == cid), None)
        if lid is None: report["skipped"]["membership_missing_link"] += 1; continue
    start = date_only(r["from"]) or date_only(r["createdOn"])
    end = date_only(r["to"])
    if end and start and end < start: end = start
    sold = intval(r["soldById"])
    w.add(id=r["id"], membership_number=r["id"], customer_id=cid, location_id=lid, plan_type_id=pt,
          status=MEM_STATUS.get(r["status"], "cancelled"), start_date=start, end_date=end,
          billing_frequency=FREQ.get(r["billingFrequency"]), sold_by_employee_id=sold if sold in employee_ids else None,
          cancelled_on=date_only(r["cancellationDate"]), st_id=r["id"])
w.close()

# ---------------------------------------------------------------------------
# 9. Equipment + warranty coverages
# ---------------------------------------------------------------------------
w = Writer("equipment", ["id", "location_id", "equipment_type_id", "manufacturer_id", "model_number", "serial_number",
                         "install_date", "installed_by_company", "status", "notes", "st_id"])
wc = []
equipment_ids = set()
for r in rows("installed-equipment.csv"):
    lid = intval(r["locationId"])
    if lid not in location_ids:
        report["skipped"]["equipment_without_location"] += 1; continue
    t = j(r["type"], {}) or {}
    tname = t.get("name") or ""
    if not tname:
        nm = (r["name"] or "").split("-")[0].strip()
        tname = nm if nm and len(nm) < 40 else "Unknown"
    notes = "; ".join(x for x in [clean_text(r["name"], 300), clean_text(r["memo"], 1000)] if x) or None
    w.add(id=r["id"], location_id=lid, equipment_type_id=equipment_type_id(tname),
          manufacturer_id=manufacturer_id(r["manufacturer"]), model_number=(r["model"] or "").strip() or None,
          serial_number=(r["serialNumber"] or "").strip() or None, install_date=date_only(r["installedOn"]),
          installed_by_company=b(bool(r["invoiceItemId"])),
          status="active" if r["active"] == "true" else "removed", notes=notes, st_id=r["id"])
    equipment_ids.add(int(r["id"]))
    eid = int(r["id"])
    ms, me = date_only(r["manufacturerWarrantyStart"]), date_only(r["manufacturerWarrantyEnd"])
    if ms and me and me >= ms:
        wc.append(dict(equipment_id=eid, covers_parts="true", covers_labour="false", source="manufacturer",
                       provider_name=r["manufacturer"] or None, start_date=ms, end_date=me))
    ss, se = date_only(r["serviceProviderWarrantyStart"]), date_only(r["serviceProviderWarrantyEnd"])
    if se:
        ss = ss or ms or date_only(r["installedOn"]) or se
        if se >= ss:
            wc.append(dict(equipment_id=eid, covers_parts="false", covers_labour="true", source="company_workmanship",
                           provider_name="Reid Heating & Cooling", start_date=ss, end_date=se))
w.close()
today = datetime.now(TZ).date().isoformat()
w = Writer("warranty_coverages", ["equipment_id", "covers_parts", "covers_labour", "source", "provider_name",
                                  "start_date", "end_date", "requires_annual_maintenance", "status"])
for c in wc:
    w.add(**c, requires_annual_maintenance="false", status="active" if c["end_date"] >= today else "expired")
w.close()
report["notes"].append("Warranty coverages were imported without the 'requires yearly maintenance' flag, "
                       "because ServiceTitan doesn't record it; set it on new installs going forward.")

# ---------------------------------------------------------------------------
# 10. Estimates (each ServiceTitan estimate = one estimate with one option)
# ---------------------------------------------------------------------------
EST_STATUS = {"Open": "sent", "Sold": "accepted", "Dismissed": "lost"}
est_ids = known("estimate_ids")
we = Writer("estimates", ["id", "estimate_number", "job_id", "project_id", "customer_id", "location_id",
                          "business_unit_id", "sold_by_employee_id", "status", "accepted_option_id", "accepted_at",
                          "lost_reason", "st_id", "created_at"])
wo = Writer("estimate_options", ["id", "estimate_id", "sequence", "name", "description", "is_recommended"])
wl = Writer("estimate_lines", ["estimate_option_id", "sequence", "item_id", "description", "quantity", "unit_price",
                               "unit_cost", "taxable"])
for r in rows("estimates.csv"):
    cid, lid = intval(r["customerId"]), intval(r["locationId"])
    if cid not in customer_ids or lid not in location_ids:
        report["skipped"]["estimate_missing_link"] += 1; continue
    st = (j(r["status"], {}) or {}).get("name", "Open")
    status = EST_STATUS.get(st, "sent")
    eid = int(r["id"]); jid = intval(r["jobId"])
    sold = intval(r["soldBy"])
    bu = (j(r["businessUnitId"]) if False else None)
    unit = unit_for(intval(r["businessUnitId"]), job_type_of_job.get(jid))[0]
    we.add(id=eid, estimate_number=r["id"], job_id=jid if jid in job_ids else None,
           project_id=intval(r["projectId"]) if intval(r["projectId"]) in project_ids else None,
           customer_id=cid, location_id=lid, business_unit_id=UNIT_IDS[unit],
           sold_by_employee_id=sold if sold in employee_ids else None, status=status,
           accepted_option_id=eid if status == "accepted" else None,
           accepted_at=ts(r["soldOn"]) if status == "accepted" else None,
           lost_reason="other" if status == "lost" else None, st_id=r["id"], created_at=ts(r["createdOn"]))
    wo.add(id=eid, estimate_id=eid, sequence=1, name=clean_text(r["name"], 300) or "Option 1",
           description=clean_text(r["summary"], 4000), is_recommended=b(r["isRecommended"]))
    for i, it in enumerate(j(r["items"], []) or [], 1):
        sku = it.get("sku") or {}
        wl.add(estimate_option_id=eid, sequence=i, item_id=pb_lookup(sku.get("type"), sku.get("id")),
               description=clean_text(it.get("description"), 4000) or sku.get("displayName") or "Item",
               quantity=num(it.get("qty"), 1), unit_price=num(it.get("unitRate"), 0),
               unit_cost=num(it.get("unitCost"), 0), taxable="true")
    est_ids.add(eid)
we.close(); wo.close(); wl.close()

w = Writer("job_sold_estimates", ["job_id", "estimate_id"])
for jid, eid in sold_from:
    if eid in est_ids: w.add(job_id=jid, estimate_id=eid)
w.close()

# ---------------------------------------------------------------------------
# 11. Invoices + lines
# ---------------------------------------------------------------------------
inv_ids = known("invoice_ids")
inv_tax_rate = {int(k): v for k, v in known("invoice_tax_rate", dict).items()}
w = Writer("invoices", ["id", "invoice_number", "job_id", "customer_id", "location_id", "business_unit_id", "channel",
                        "status", "invoice_date", "payment_terms_days", "po_number", "subtotal", "tax_total", "total",
                        "amount_paid", "sent_at", "st_id", "created_at"])
for r in rows("invoices.csv"):
    cust = j(r["customer"], {}) or {}; loc = j(r["location"], {}) or {}; jb = j(r["job"], {}) or {}
    bu = j(r["businessUnit"], {}) or {}
    cid = cust.get("id")
    if cid not in customer_ids:
        report["skipped"]["invoice_without_customer"] += 1; continue
    jid = jb.get("id") if jb.get("id") in job_ids else None
    unit = unit_for(bu.get("id"), job_type_of_job.get(jb.get("id")))[0]
    total, bal = num(r["total"], 0), num(r["balance"], 0)
    sub, tax = num(r["subTotal"], 0), num(r["salesTax"], 0)
    if total == 0 and sub == 0: status = "posted"
    elif abs(bal) < 0.005: status = "paid"
    elif abs(bal) < abs(total): status = "partially_paid"
    else: status = "posted"
    idate = date_only(r["invoiceDate"]) or date_only(r["createdOn"])
    ddate = date_only(r["dueDate"])
    terms = 0
    if idate and ddate:
        terms = max((datetime.fromisoformat(ddate) - datetime.fromisoformat(idate)).days, 0)
    channel = "job" if jid else ("recurring" if r["membershipId"] else "pos")
    w.add(id=r["id"], invoice_number=r["referenceNumber"] or r["id"], job_id=jid, customer_id=cid,
          location_id=loc.get("id") if loc.get("id") in location_ids else None, business_unit_id=UNIT_IDS[unit],
          channel=channel, status=status, invoice_date=idate, payment_terms_days=terms, po_number=None,
          subtotal=sub, tax_total=tax, total=total, amount_paid=round(total - bal, 2),
          sent_at=None, st_id=r["id"], created_at=ts(r["createdOn"]))
    iid = int(r["id"]); inv_ids.add(iid)
    inv_tax_rate[iid] = round(tax / sub * 100, 2) if sub and tax and 0 < tax / sub < 0.2 else 0
w.close()

LINE_TYPE = {"Service": "item", "Material": "item", "Equipment": "item", "PriceModifier": "discount",
             "Membership": "plan", "Discount": "discount"}
w = Writer("invoice_lines", ["id", "invoice_id", "sequence", "line_type", "item_id", "description", "quantity",
                             "unit_price", "unit_cost", "taxable", "tax_rate_pct", "technician_id", "st_id"])
seqs = defaultdict(int)
for r in rows("invoice-items.csv"):
    iid = intval(r["invoiceId"])
    if iid not in inv_ids or r["active"] != "true":
        report["skipped"]["invoice_line"] += 1; continue
    seqs[iid] += 1
    tech = intval(r["technicianId"])
    taxable = r["taxable"] == "true"
    w.add(id=r["id"], invoice_id=iid, sequence=intval(r["order"]) or seqs[iid], line_type=LINE_TYPE.get(r["type"], "other"),
          item_id=pb_lookup(r["type"], intval(r["skuId"])),
          description=clean_text(r["description"], 4000) or clean_text(r["displayName"]) or r["skuName"] or "Item",
          quantity=num(r["quantity"], 1), unit_price=num(r["price"], 0), unit_cost=num(r["cost"], 0),
          taxable=b(taxable), tax_rate_pct=inv_tax_rate.get(iid, 0) if taxable else 0,
          technician_id=tech if tech in employee_ids else None, st_id=r["id"])
w.close()

# ---------------------------------------------------------------------------
# 12. Payments + applications
# ---------------------------------------------------------------------------
def pay_method(t):
    t = (t or "").lower()
    if "auto bank deposit" in t: return "partner_remittance"
    if "pap" in t: return "autopay"
    if any(k in t for k in ("visa", "master", "amex", "debit", "online", "credit card")): return "card"
    if "etransfer" in t or "e-transfer" in t: return "e_transfer"
    if "cheque" in t or "check" in t: return "cheque"
    if "cash" in t: return "cash"
    if "applied payment" in t or "credit" in t: return "credit"
    if "financ" in t: return "financing"
    return "eft"
wp = Writer("payments", ["id", "payment_number", "payer_type", "customer_id", "method", "amount", "received_on",
                         "reference", "status", "amount_applied", "notes", "st_id", "created_at"])
wa = Writer("payment_applications", ["payment_id", "invoice_id", "amount", "applied_at"])
for r in rows("payments.csv"):
    cust = j(r["customer"], {}) or {}
    cid = cust.get("id")
    amt = num(r["total"], 0)
    if cid not in customer_ids or not amt:
        report["skipped"]["payment_without_customer_or_zero"] += 1; continue
    apps = []
    for a in j(r["appliedTo"], []) or []:
        inv, am = a.get("appliedTo"), num(a.get("appliedAmount"), 0)
        if inv in inv_ids and am: apps.append((inv, am, ts(a.get("appliedOn"))))
    applied = round(sum(a[1] for a in apps), 2)
    pid = int(r["id"])
    ref = r["referenceNumber"] or r["checkNumber"] or r["authCode"] or None
    wp.add(id=pid, payment_number=r["id"], payer_type="customer", customer_id=cid, method=pay_method(r["type"]),
           amount=amt, received_on=date_only(r["date"]) or date_only(r["createdOn"]), reference=ref, status="succeeded",
           amount_applied=applied, notes=" | ".join(x for x in [r["type"], clean_text(r["memo"], 500)] if x) or None,
           st_id=r["id"], created_at=ts(r["createdOn"]))
    for inv, am, on in apps:
        wa.add(payment_id=pid, invoice_id=inv, amount=am, applied_at=on or ts(r["date"]))
wp.close(); wa.close()

# ---------------------------------------------------------------------------
# 13. Leads (bookings + leads)
# ---------------------------------------------------------------------------
w = Writer("leads", ["id", "lead_number", "source", "customer_id", "contact_name", "contact_phone", "contact_email",
                     "address_text", "requested_service", "status", "st_id", "created_at"])
lead_n = 0
for r in rows("bookings.csv"):
    lead_n += 1
    a = j(r["address"], {}) or {}
    w.add(id=r["id"], lead_number=f"B-{r['id']}", source="online_booking", customer_id=None,
          contact_name=clean_text(r["name"], 200), address_text=", ".join(x for x in [a.get("street"), a.get("city")] if x) or None,
          requested_service=clean_text(r["summary"], 2000),
          status="converted" if r["jobId"] else ("lost" if r["status"] == "Dismissed" else "new"),
          st_id=r["id"], created_at=ts(r["createdOn"]))
for r in rows("leads.csv"):
    w.add(id=r["id"], lead_number=f"L-{r['id']}", source="phone",
          customer_id=intval(r["customerId"]) if intval(r["customerId"]) in customer_ids else None,
          contact_name=clean_text(r["leadCustomerName"], 200), contact_phone=r["leadPhone"] or None,
          contact_email=r["leadEmail"] or None, requested_service=clean_text(r["summary"], 2000),
          status="lost" if r["status"] == "Dismissed" else "new", st_id=r["id"], created_at=ts(r["createdOn"]))
w.close()

# lookup lists created on the way
w = Writer("suppliers", ["id", "name"])
for name, i in suppliers.items():
    if DELTA is None or name in NEW_SUPPLIERS: w.add(id=i, name=name)
w.close()
w = Writer("manufacturers", ["id", "name"])
seen = set()
for key, (i, name) in manufacturers.items():
    nm = name if name.lower() not in seen else f"{name} ({i})"; seen.add(nm.lower())
    if DELTA is None or key in NEW_MANUFACTURERS: w.add(id=i, name=nm)
w.close()
w = Writer("equipment_types", ["id", "name"])
seen = set()
for key, (i, name) in equipment_types.items():
    nm = name if name.lower() not in seen else f"{name} ({i})"; seen.add(nm.lower())
    if DELTA is None or key in NEW_EQUIPMENT_TYPES: w.add(id=i, name=nm)
w.close()

# ---------------------------------------------------------------------------
# manifest: load order (parents before children)
# ---------------------------------------------------------------------------
LOAD_ORDER = ["business_units", "business_unit_migration_map", "partners", "suppliers", "manufacturers",
              "equipment_types", "employees", "customers", "customer_flags", "locations", "customer_contacts",
              "job_types", "pricebook_items", "pricebook_kit_items", "projects", "jobs", "visits",
              "visit_assignments", "plan_types", "memberships", "equipment", "warranty_coverages",
              "estimates", "estimate_options", "estimate_lines", "job_sold_estimates",
              "invoices", "invoice_lines", "payments", "payment_applications", "leads"]
writers = {wr.table: wr for wr in Writer.order}
manifest = [{"table": t, "file": f"{t}.csv", "columns": writers[t].columns, "rows": writers[t].n} for t in LOAD_ORDER if t in writers]
json.dump({"tables": manifest}, open(os.path.join(OUT, "manifest.json"), "w"), indent=1)
report["skipped"] = dict(report["skipped"])
json.dump(report, open(os.path.join(OUT, "report.json"), "w"), indent=1)
if DELTA is None: print(json.dumps(report, indent=1))

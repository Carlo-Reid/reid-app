"""Puts customer addresses on the map: finds the latitude / longitude of every address that doesn't have one yet.

1. The Statistics Canada Open Database of Addresses (Ontario): every civic address the City of Ottawa
   and nearby towns publish, with its exact spot. Free, Open Government Licence - Canada.
2. Not in the list (a newer house)? Its spot is estimated between the neighbours on the same street.
3. Still not found? One lookup each on OpenStreetMap's free search (slowly: one a second, as they ask).
Only addresses with no spot are touched. Each one found says how (locations.geo_source).
The log shows counts only (no addresses). Settings come from the repository's secrets."""
import csv, io, math, os, re, sys, time, urllib.request, urllib.parse, json, zipfile, tempfile, argparse
from collections import defaultdict

ODA_URL = "https://www150.statcan.gc.ca/n1/en/pub/46-26-0001/2021001/ODA_ON_v1.zip"
# the area Reid works in (Ottawa and the towns around it, Gatineau too)
BOX = (44.70, 46.00, -76.90, -74.40)   # lat min, lat max, lon min, lon max
SEARCH_UA = "ReidHVAC-address-map/1.0 (+https://github.com/Carlo-Reid/reid-app)"

TYPES = {"STREET": "ST", "STR": "ST", "ST": "ST", "RUE": "ST", "AVENUE": "AVE", "AV": "AVE", "AVE": "AVE", "ROAD": "RD", "RD": "RD", "CHEMIN": "RD", "CH": "RD",
         "DRIVE": "DR", "DR": "DR", "CRESCENT": "CRES", "CRES": "CRES", "CRESC": "CRES", "CR": "CRES", "COURT": "CRT", "CRT": "CRT", "CT": "CRT",
         "PLACE": "PL", "PL": "PL", "BOULEVARD": "BLVD", "BLVD": "BLVD", "BOUL": "BLVD", "BV": "BLVD", "WAY": "WAY", "TERRACE": "TERR", "TERR": "TERR", "TER": "TERR",
         "PRIVATE": "PVT", "PVT": "PVT", "PRIV": "PVT", "CIRCLE": "CIR", "CIR": "CIR", "CIRCT": "CIR", "LANE": "LANE", "LN": "LANE", "GATE": "GATE", "GT": "GATE",
         "TRAIL": "TRAIL", "TRL": "TRAIL", "GROVE": "GROVE", "GR": "GROVE", "HEIGHTS": "HTS", "HTS": "HTS", "PARKWAY": "PKY", "PKY": "PKY", "PKWY": "PKY",
         "RIDGE": "RIDGE", "SQUARE": "SQ", "SQ": "SQ", "HIGHWAY": "HWY", "HWY": "HWY", "LINE": "LINE", "SIDEROAD": "SDRD", "SDRD": "SDRD", "CONCESSION": "CONC",
         "CONC": "CONC", "VIEW": "VIEW", "CLOSE": "CLOSE", "WALK": "WALK", "ROW": "ROW", "MEWS": "MEWS", "PATH": "PATH", "LANDING": "LANDNG", "LANDNG": "LANDNG",
         "GARDENS": "GDNS", "GDNS": "GDNS", "GREEN": "GREEN", "PARK": "PK", "PK": "PK", "POINT": "PT", "PT": "PT", "HILL": "HILL", "BAY": "BAY", "COMMON": "COMMON",
         "ACRES": "ACRES", "GLEN": "GLEN", "WOOD": "WOOD", "CROSSING": "CROSS", "CROSS": "CROSS", "RUN": "RUN", "LOOP": "LOOP", "END": "END", "ISLAND": "ISLAND"}
DIRS = {"NORTH": "N", "N": "N", "NORD": "N", "SOUTH": "S", "S": "S", "SUD": "S", "EAST": "E", "E": "E", "EST": "E", "WEST": "W", "W": "W", "OUEST": "W", "O": "W",
        "NE": "NE", "NW": "NW", "SE": "SE", "SW": "SW", "NORTHEAST": "NE", "NORTHWEST": "NW", "SOUTHEAST": "SE", "SOUTHWEST": "SW"}
WORDS = {"SAINT": "ST", "STE": "STE", "SAINTE": "STE", "MOUNT": "MT", "MT": "MT", "FORT": "FT"}
# the old towns now inside the City of Ottawa
OTTAWA = {"OTTAWA", "NEPEAN", "KANATA", "ORLEANS", "GLOUCESTER", "STITTSVILLE", "BARRHAVEN", "VANIER", "CUMBERLAND", "MANOTICK", "GREELY", "CARP", "RICHMOND",
          "MUNSTER", "NAVAN", "OSGOODE", "METCALFE", "NORTH GOWER", "DUNROBIN", "CONSTANCE BAY", "FITZROY HARBOUR", "KARS", "VARS", "SARSFIELD", "WOODLAWN",
          "ROCKCLIFFE", "ROCKCLIFFE PARK", "BLACKBURN HAMLET", "RIVERSIDE SOUTH", "WEST CARLETON", "GOULBOURN", "RIDEAU", "KINBURN", "GALETTA", "VERNON", "CARLSBAD SPRINGS", "ASHTON", "MUNSTER HAMLET", "LEITRIM", "FINDLAY CREEK", "OTTAWA ON"}

def clean(s): return re.sub(r"\s+", " ", re.sub(r"[.,'’`\"#()/]", " ", (s or "").upper().replace("-", " "))).strip()

def norm_street(name):
    """'Bell Street North' -> core 'BELL', type 'ST', dir 'N' (also 'rue Boake' -> 'BOAKE', 'ST')."""
    t = clean(name).split()
    t = [WORDS.get(x, x) if i < len(t) - 1 else x for i, x in enumerate(t)]
    typ = dirn = ""
    if len(t) > 1 and t[-1] in DIRS: dirn = DIRS[t.pop()]
    if len(t) > 1 and t[-1] in TYPES: typ = TYPES[t.pop()]
    if len(t) > 1 and t[0] in ("RUE", "AVENUE", "CHEMIN", "BOULEVARD", "PROMENADE", "CROISSANT", "PLACE", "PROM", "CROIS", "IMPASSE", "PRIVE", "PRIVÉ") and not typ:
        typ = TYPES.get(t[0], {"PROMENADE": "DR", "PROM": "DR", "CROISSANT": "CRES", "CROIS": "CRES", "IMPASSE": "CRT", "PRIVE": "PVT", "PRIVÉ": "PVT"}.get(t[0], "")); t = t[1:]
    if len(t) > 1 and t[0] in DIRS and not dirn: dirn = DIRS[t[0]]; t = t[1:]
    return " ".join(t), typ, dirn

UNIT_RX = re.compile(r"\b(UNIT|APT|APARTMENT|SUITE|STE|BUREAU|APP|#)\s*\w+\s*$", re.I)
def split_address(street):
    """'1630 Rangeland Ave' -> (1630, 'RANGELAND', 'AVE', ''); '5-123 Main St' -> number 123."""
    s = UNIT_RX.sub("", (street or "").strip())
    m = re.match(r"^\s*(?:[A-Za-z]?\d+[A-Za-z]?\s*[-–]\s*)?(\d+)\s*([A-Za-z]|1/2)?\b[\s,]+(.+)$", s)
    if not m: return None
    core, typ, dirn = norm_street(m.group(3))
    if not core: return None
    return int(m.group(1)), core, typ, dirn

def town(c):
    c = clean(c)
    return "OTTAWA" if c in OTTAWA else c

def km(a, b):
    dy = (a[0] - b[0]) * 111.0; dx = (a[1] - b[1]) * 111.0 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)

def load_addresses(path):
    """The address list, only the area Reid works in: {(number, core): [(lat, lon, type, dir, town, fsa)]} and the streets for estimates."""
    idx = defaultdict(list); streets = defaultdict(list); n = 0
    with zipfile.ZipFile(path) as z:
        name = next(x for x in z.namelist() if x.lower().endswith(".csv"))
        with z.open(name) as f:
            for r in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8", errors="replace")):
                try: lat, lon = float(r["latitude"]), float(r["longitude"])
                except (TypeError, ValueError, KeyError): continue
                if not (BOX[0] <= lat <= BOX[1] and BOX[2] <= lon <= BOX[3]): continue
                num = re.match(r"^\s*(\d+)", r.get("street_no") or "")
                if not num: continue
                st = r.get("street") or " ".join(x for x in (r.get("str_name"), r.get("str_type"), r.get("str_dir")) if x)
                core, typ, dirn = norm_street(st)
                if not core: continue
                tw = town(r.get("csdname") or r.get("city") or r.get("city_pcs") or "")
                fsa = clean(r.get("postal_code") or "").replace(" ", "")[:3]
                rec = (lat, lon, typ, dirn, tw, fsa)
                idx[(int(num.group(1)), core)].append(rec)
                streets[(core, typ, dirn, tw)].append((int(num.group(1)), lat, lon))
                n += 1
    for k in streets: streets[k].sort()
    return idx, streets, n

def pick(cands, typ, dirn, tw, fsa):
    """The one spot for an address, or None when it's not clear which one it is."""
    for test in (lambda c: not typ or not c[2] or c[2] == typ, lambda c: not dirn or not c[3] or c[3] == dirn):
        keep = [c for c in cands if test(c)]
        if keep: cands = keep
    def one(cs):
        if not cs: return None
        if max(km(a, b) for a in cs for b in cs) <= 1.0:
            return (sum(c[0] for c in cs) / len(cs), sum(c[1] for c in cs) / len(cs))
        return None
    got = one(cands)
    if got: return got
    for test in (lambda c: fsa and c[5] == fsa, lambda c: tw and c[4] == tw):
        got = one([c for c in cands if test(c)])
        if got: return got
    return None

def estimate(streets, num, core, typ, dirn, tw):
    """A newer house: its spot between the nearest neighbours on the same side of the same street."""
    keys = [k for k in streets if k[0] == core and (not typ or not k[1] or k[1] == typ) and (not dirn or not k[2] or k[2] == dirn)]
    if len(keys) > 1: keys = [k for k in keys if k[3] == tw] or keys
    if len(keys) != 1: return None
    pts = [p for p in streets[keys[0]] if p[0] % 2 == num % 2] or streets[keys[0]]
    lo = max((p for p in pts if p[0] < num), default=None); hi = min((p for p in pts if p[0] > num), default=None)
    if lo and hi and hi[0] - lo[0] <= 200 and km(lo[1:], hi[1:]) <= 2.0:
        f = (num - lo[0]) / (hi[0] - lo[0]); return (lo[1] + f * (hi[1] - lo[1]), lo[2] + f * (hi[2] - lo[2]))
    near = lo if lo and (not hi or num - lo[0] <= hi[0] - num) else hi
    if near and abs(near[0] - num) <= 20: return (near[1], near[2])
    return None

def search(street, city, prov, postal):
    q = {"street": street, "city": city or "", "state": "Quebec" if (prov or "").upper().startswith("Q") else "Ontario", "country": "Canada",
         "format": "jsonv2", "limit": "1", "countrycodes": "ca", "viewbox": f"{BOX[2]},{BOX[1]},{BOX[3]},{BOX[0]}", "bounded": "1"}
    if postal and re.match(r"^[A-Z]\d[A-Z] ?\d[A-Z]\d$", postal.upper().strip()): q["postalcode"] = postal.upper().strip()
    for attempt in (q, {k: v for k, v in q.items() if k != "postalcode"}):
        req = urllib.request.Request("https://nominatim.openstreetmap.org/search?" + urllib.parse.urlencode(attempt), headers={"User-Agent": SEARCH_UA})
        try:
            with urllib.request.urlopen(req, timeout=30) as r: res = json.load(r)
        except Exception:
            res = []
        time.sleep(1.1)
        AREA = ("road", "city", "town", "village", "hamlet", "suburb", "quarter", "neighbourhood", "county", "state", "postcode", "municipality", "country", "region")
        if res and res[0].get("category") not in ("highway", "boundary") and res[0].get("addresstype") not in AREA:   # a house, not just the street or the town
            lat, lon = float(res[0]["lat"]), float(res[0]["lon"])
            if BOX[0] <= lat <= BOX[1] and BOX[2] <= lon <= BOX[3]: return (lat, lon)
        if res: return None   # found only a street or a town: not good enough
    return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", help="the address list zip, if already downloaded")
    ap.add_argument("--search-max", type=int, default=int(os.environ.get("SEARCH_MAX", "2500")), help="most lookups on the free map search per run")
    ap.add_argument("--dry", action="store_true", help="count only, change nothing")
    a = ap.parse_args()
    import psycopg
    conn = psycopg.connect(host=os.environ["DB_HOST"], port=int(os.environ.get("DB_PORT") or 5432), dbname=os.environ["DB_NAME"], user=os.environ["DB_USER"],
                           password=os.environ["DB_PASSWORD"], sslmode=os.environ.get("DB_SSLMODE", "require"), connect_timeout=30)
    with conn.cursor() as cur:
        cur.execute("ALTER TABLE public.locations ADD COLUMN IF NOT EXISTS geo_source text; ALTER TABLE public.locations ADD COLUMN IF NOT EXISTS geo_at timestamptz;")
        cur.execute("""SELECT id, street, city, province, postal_code FROM public.locations
                       WHERE latitude IS NULL AND coalesce(btrim(street), '') <> '' AND (geo_source IS NULL OR geo_source <> 'not found')""")
        todo = cur.fetchall()
    conn.commit()
    print(f"::notice title=Addresses without a map spot::{len(todo)}", flush=True)
    print(f"Addresses with no spot on the map: {len(todo)}", flush=True)
    if not todo: return

    path = a.file
    if not path:
        print("Downloading the Statistics Canada address list…", flush=True)
        path = os.path.join(tempfile.gettempdir(), "oda_on.zip")
        req = urllib.request.Request(ODA_URL, headers={"User-Agent": SEARCH_UA})
        with urllib.request.urlopen(req, timeout=600) as r, open(path, "wb") as f:
            while True:
                b = r.read(1 << 20)
                if not b: break
                f.write(b)
    idx, streets, n = load_addresses(path)
    print(f"Addresses in the list for the Ottawa area: {n}", flush=True)

    found, how, missed = [], defaultdict(int), []
    for lid, street, city, prov, postal in todo:
        p = split_address(street)
        if not p: missed.append((lid, street, city, prov, postal)); how["no house number"] += 1; continue
        num, core, typ, dirn = p
        tw, fsa = town(city), clean(postal).replace(" ", "")[:3]
        spot = pick(idx.get((num, core), []), typ, dirn, tw, fsa)
        if spot: found.append((lid, spot, "address list")); how["address list"] += 1; continue
        spot = estimate(streets, num, core, typ, dirn, tw)
        if spot: found.append((lid, spot, "street estimate")); how["street estimate"] += 1; continue
        missed.append((lid, street, city, prov, postal))

    searched = 0
    for lid, street, city, prov, postal in missed:
        if searched >= a.search_max or a.dry: break
        if not split_address(street): continue
        searched += 1
        spot = search(street, city, prov, postal)
        if spot: found.append((lid, spot, "map search")); how["map search"] += 1
        else: how["not found"] += 1; found.append((lid, None, "not found"))

    for k in ("address list", "street estimate", "map search", "not found", "no house number"):
        print(f"  {k}: {how.get(k, 0)}", flush=True)
    print("::notice title=Map counts::" + ", ".join(f"{k} {how.get(k, 0)}" for k in ("address list", "street estimate", "map search", "not found", "no house number")), flush=True)
    left = len(missed) - searched
    if left > 0: print(f"  still to look up next run: {left}", flush=True)
    if a.dry: print("Dry run: nothing changed."); return

    with conn.cursor() as cur:
        rows = [(s[0], s[1], src, lid) for lid, s, src in found if s]
        cur.executemany("""UPDATE public.locations SET latitude = round(%s::numeric, 6), longitude = round(%s::numeric, 6), geo_source = %s, geo_at = now()
                           WHERE id = %s AND latitude IS NULL""", rows)
        cur.executemany("UPDATE public.locations SET geo_source = 'not found', geo_at = now() WHERE id = %s AND latitude IS NULL", [(lid,) for lid, s, src in found if not s])
    conn.commit()
    print(f"Put on the map: {sum(1 for x in found if x[1])}", flush=True)

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"::error::Stopped: {type(e).__name__}", flush=True)   # no details: they could hold an address
        sys.exit(1)

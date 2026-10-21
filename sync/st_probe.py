"""One-off check: which ServiceTitan inventory lists this app key can read.
Prints counts and field names only (no customer data) as notes on the Actions page."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
import st_sync as S

clean = lambda k: os.environ.get("ST_" + k, "").strip().strip('"').strip("'")
st = S.ST({k: clean(k) for k in ("TENANT_ID", "APP_KEY", "CLIENT_ID", "CLIENT_SECRET")})
paths = ["inventory/v2/tenant/{t}/warehouses", "inventory/v2/tenant/{t}/trucks", "inventory/v2/tenant/{t}/adjustments",
         "inventory/v2/tenant/{t}/transfers", "inventory/v2/tenant/{t}/receipts", "inventory/v2/tenant/{t}/returns",
         "inventory/v2/tenant/{t}/inventory-bills", "inventory/v2/tenant/{t}/warehouses/inventory", "inventory/v2/tenant/{t}/trucks/inventory",
         "pricebook/v2/tenant/{t}/materials", "pricebook/v2/tenant/{t}/equipment"]
def keys(o, depth=0):
    out = []
    for k, v in (o or {}).items():
        out.append(k)
        if depth < 1 and isinstance(v, list) and v and isinstance(v[0], dict): out.append(k + "[" + ",".join(list(v[0].keys())[:25]) + "]")
        if depth < 1 and isinstance(v, dict): out.append(k + "{" + ",".join(list(v.keys())[:25]) + "}")
    return out
for p in paths:
    name = p.split("/tenant/{t}/")[1]
    try:
        o = st.get(p, {"page": 1, "pageSize": 5, "includeTotal": "true"})
        d = o.get("data") or []
        print(f"::notice::{name}: total {o.get('totalCount', '?')}, hasMore {o.get('hasMore')}; fields: {', '.join(keys(d[0]) if d else [])[:900]}", flush=True)
    except Exception as e:
        print(f"::notice::{name}: not available ({str(e)[:160]})", flush=True)

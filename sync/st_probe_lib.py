"""Which ServiceTitan inventory lists the app key can read: counts and field names only, as notes on the Actions page."""

def run(st):
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

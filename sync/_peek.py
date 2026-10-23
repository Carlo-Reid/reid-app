import os, re, sys
sys.path.insert(0, "sync"); import eft_mail as m
db = m.connect_db(); cur = db.cursor()
cur.execute("SELECT f.id, f.file_name, f.data FROM pap_mail_file f WHERE lower(f.file_name) LIKE '%.xls' ORDER BY f.id")
for fid, fn, data in cur.fetchall():
    data = bytes(data)
    kind = "html" if b"<table" in data[:20000].lower() else ("ole" if data[:4] == b"\xd0\xcf\x11\xe0" else "other:" + repr(data[:8]))
    rows = m.sheets_of(fn, data)
    out = [f"file {fid} {kind} rows={len(rows)}"]
    for k, r in enumerate(rows[:60]):
        shape = []
        for v in r:
            if not v: shape.append("."); continue
            if len(v) <= 40 and re.search(m.HEADWORD + r"|^id$|first|last|settled|process|return", v, re.I): shape.append(re.sub(r"\d", "9", v))
            else: shape.append(re.sub(r"[A-Za-z]", "a", re.sub(r"\d", "9", v))[:6])
        cells = [f"{j + 1}={x}" for j, x in enumerate(shape) if x != "."]
        if cells: out.append(f"r{k + 1}: " + " ".join(cells))
    print("::notice::" + " // ".join(out)[:4000])

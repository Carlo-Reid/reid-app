import os, re, sys
sys.path.insert(0, "sync"); import eft_mail as m
db = m.connect_db(); cur = db.cursor()
cur.execute("SELECT f.id, f.file_name, f.data FROM pap_mail_file f WHERE lower(f.file_name) LIKE '%.xls' ORDER BY f.id")
for fid, fn, data in cur.fetchall():
    data = bytes(data)
    kind = "html" if b"<table" in data[:20000].lower() else ("ole" if data[:4] == b"\xd0\xcf\x11\xe0" else "other:" + repr(data[:8]))
    rows = m.sheets_of(fn, data)
    print(f"::notice::file {fid} kind={kind} rows={len(rows)} widths={[len(r) for r in rows[:12]]}")
    for k, r in enumerate(rows[:14]):
        shape = []
        for v in r:
            if not v: shape.append("."); continue
            if len(v) <= 40 and re.search(m.HEADWORD + r"|^id$|first|last|settled|process|return", v, re.I): shape.append(re.sub(r"\d", "9", v))
            else: shape.append(re.sub(r"[A-Za-z]", "a", re.sub(r"\d", "9", v))[:6])
        print(f"::notice::file {fid} row {k + 1}: " + " | ".join(shape)[:900])

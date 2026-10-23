"""Checks the EFT mailbox (eftupload@hsginc.ca) for PAP / EFT lists sent as Excel (or CSV) attachments.

Every email is kept in the app's database (pap_mail), with its attachments and the whole original message, so owners
can look at them any time on the Security page. The attachments hold bank details: only owners can open them, and
each time one is opened it's written to History. Nothing about the emails is ever shown in the run log.
From each Excel / CSV file it also takes the customer #, name and phone columns as a list to review. That list waits on the Security page until an owner reviews it and clicks Mark: nothing changes on its own.
Which list: Monthly billing, unless the email subject (or file name) says "Other".

Runs on GitHub every 10 minutes (.github/workflows/eft-mail.yml). The mailbox details come from the repository's
secrets (EFT_IMAP_PASS, and IMAP_HOST / IMAP_PORT shared with supplier mail), never from the code. It only reads
the mailbox: nothing is deleted, moved or marked as read.
"""
import os, sys, ssl, time, imaplib, email, hashlib, re, datetime, io, csv, json, html
from email.header import decode_header, make_header
from email.utils import parseaddr, parsedate_to_datetime

QUIET = bool(os.environ.get("GITHUB_ACTIONS"))
KEEP = (".xlsx", ".xlsm", ".xls", ".csv")
MAX_FILE = 15 * 1024 * 1024


def say(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)
    if QUIET:
        print("::notice title=EFT mail::" + msg, flush=True)   # counts only, never email or file details


def hdr(v):
    try:
        return str(make_header(decode_header(v or ""))).strip()
    except Exception:
        return (v or "").strip()


def body_text(msg):
    plain, html = [], []
    for part in msg.walk():
        if part.is_multipart() or part.get_filename():
            continue
        ct = part.get_content_type()
        if ct not in ("text/plain", "text/html"):
            continue
        try:
            t = part.get_payload(decode=True).decode(part.get_content_charset() or "utf-8", "replace")
        except Exception:
            continue
        (plain if ct == "text/plain" else html).append(t)
    if plain:
        t = "\n".join(plain)
    else:
        t = re.sub(r"(?is)<(script|style).*?</\1>", " ", " ".join(html))
        t = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</tr>", "\n", t)
        t = re.sub(r"<[^>]+>", " ", t).replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    t = re.sub(r"[ \t\r\f\v]+", " ", t)
    return re.sub(r"\n\s*\n\s*\n+", "\n\n", t).strip()[:200000]


def all_files(msg):
    """Every attachment, whatever kind it is (to keep with the email)."""
    out = []
    for part in msg.walk():
        if part.is_multipart():
            continue
        name = hdr(part.get_filename() or "")
        if not name:
            continue
        data = part.get_payload(decode=True) or b""
        if data and len(data) <= MAX_FILE:
            out.append((name[:200], part.get_content_type(), data))
    return out


def files_of(msg):
    out = []
    for part in msg.walk():
        if part.is_multipart():
            continue
        name = hdr(part.get_filename() or "")
        if not name or not name.lower().endswith(KEEP):
            continue
        data = part.get_payload(decode=True) or b""
        if data and len(data) <= MAX_FILE:
            out.append((name[:200], data))
    return out


def cell(v):
    """A cell as text, the way Excel shows it (12345.0 -> 12345, &amp; -> &)."""
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    if isinstance(v, (datetime.datetime, datetime.date)):
        return v.isoformat()[:10]
    return html.unescape(str(v)).strip()


def sheets_of(name, data):
    """Every row of every sheet, as lists of text. (Some banks send a web page named .xls: that's read too.)"""
    low = name.lower()
    if low.endswith(".csv"):
        text = data.decode("utf-8-sig", "replace")
        try:
            dialect = csv.Sniffer().sniff(text[:4000], delimiters=",;\t")
        except Exception:
            dialect = csv.excel
        return [[cell(v) for v in r] for r in csv.reader(io.StringIO(text), dialect)]
    head = data[:2000].lstrip().lower()
    if head.startswith((b"<", b"\xef\xbb\xbf<")) or b"<table" in data[:20000].lower():
        rows = []
        for tr in re.findall(r"(?is)<tr[^>]*>(.*?)</tr>", data.decode("utf-8", "replace")):
            rows.append([cell(re.sub(r"(?s)<[^>]+>", " ", c)).replace("\xa0", " ").strip() for c in re.findall(r"(?is)<t[dh][^>]*>(.*?)</t[dh]>", tr)])
        return rows
    if low.endswith(".xls"):
        try:
            import xlrd
            wb = xlrd.open_workbook(file_contents=data)
            rows = []
            for sh in wb.sheets():
                for r in range(sh.nrows):
                    out = []
                    for c in range(sh.ncols):
                        x = sh.cell(r, c)
                        if x.ctype == xlrd.XL_CELL_DATE:   # Excel keeps dates as numbers: show them like the bank does
                            try:
                                out.append(xlrd.xldate_as_datetime(x.value, wb.datemode).strftime("%d-%b-%Y")); continue
                            except Exception:
                                pass
                        out.append(cell(x.value))
                    rows.append(out)
            return rows
        except Exception:
            text = data.decode("utf-8", "replace")   # a tab-separated text file named .xls
            if "\t" in text:
                return [[cell(v) for v in line.split("\t")] for line in text.splitlines()]
            raise
    import openpyxl
    wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    rows = []
    for ws in wb.worksheets:
        for r in ws.iter_rows(values_only=True):
            rows.append([cell(v) for v in r])
    return rows


def guess(lc, tests, skip=()):
    for t in tests:
        for j, h in enumerate(lc):
            if j not in skip and re.search(t, h):
                return j
    return -1


READER = "3"
HEADWORD = r"customer|cust\b|client|name|reference|\bref\b|phone|amount|response|status|transaction|date|type|payor|payer|settled"
BANKCOL = r"bank|transit|institution|routing|branch|acct|account|iban|swift|card"


def read_list(name, data):
    """The file's own table (every column except bank details) plus, for matching, per row:
    customer #, name, phone, amount, response."""
    allrows = sheets_of(name, data)
    # the heading row: the one near the top with the most heading words (bank reports put totals above the table)
    score = [sum(1 for v in r if v and len(v) <= 40 and re.search(HEADWORD, v, re.I)) for r in allrows[:200]]
    if not score or max(score) < 3:   # a real heading row has several headings (Transaction ID, First Name, Amount...)
        return None, None, "No list of customers was found in the file (it may have no transactions this time).", None, None
    hi = max(range(len(score)), key=lambda k: (score[k], -k))
    head = [v.strip() for v in (allrows[hi] if allrows else [])]
    lc = [h.lower() for h in head]
    bank = tuple(j for j, h in enumerate(lc) if re.search(BANKCOL, h) and not re.search(r"customer|cust\b|client|name", h))
    num = guess(lc, [r"^(customer|cust\.?|client)\s*(#|no\.?|num(ber)?|id)$", r"customer ?#|cust.*(no|num|id)|client ?(#|no|num|id)", r"^ref(erence)?\b|\bref(erence)?\s*(#|no)"], bank)
    first = guess(lc, [r"^first\s*name$|^first$|given"], bank)
    last = guess(lc, [r"^last\s*name$|^last$|surname|family"], bank)
    nm = -1 if first >= 0 else guess(lc, [r"^(customer|client)?\s*name$", r"^customer$", r"name|payor|payer"], (num,) + bank)
    ph = guess(lc, [r"phone|mobile|cell|tel"], (num, nm, first, last) + bank)
    amt = guess(lc, [r"^amount$|amount|total"], bank)
    resp = guess(lc, [r"^response$|response|status|result"], bank)
    if num < 0 and nm < 0 and first < 0 and ph < 0:
        return None, None, "No customer #, name or phone column was found in the file.", None, None
    keep = [j for j in range(len(head)) if j not in bank and (head[j] or any(j < len(r) and r[j] for r in allrows[hi + 1:hi + 50]))]
    pick = lambda r, i: (r[i] if 0 <= i < len(r) else "").strip()
    out, tbl = [], []
    for r in allrows[hi + 1:]:
        if not any(v.strip() for v in r):
            continue
        who = pick(r, nm) if nm >= 0 else " ".join(x for x in (pick(r, first), pick(r, last)) if x)
        ref = pick(r, num)
        ref = re.sub(r"\s+", "", ref) if re.match(r"(?i)^c\s*#?\s*\d", ref) else (re.split(r"[\s;/]+", ref) or [""])[0].replace(",", "")   # "27055 29088" -> the first one
        x = [ref, who, pick(r, ph), pick(r, amt), pick(r, resp)]
        if not any(x[:3]):
            continue
        out.append(x)
        tbl.append([pick(r, j)[:200] for j in keep])
    names = [head[num] if num >= 0 else None,
             head[nm] if nm >= 0 else " + ".join(head[i] for i in (first, last) if i >= 0) or None,
             head[ph] if ph >= 0 else None, head[amt] if amt >= 0 else None, head[resp] if resp >= 0 else None]
    cols = [head[j] or f"Column {j + 1}" for j in keep]
    if not out:
        return names, [], "The file has no customer rows.", cols, []
    return names, out, None, cols, tbl


def reread(cur):
    """Emailed lists that couldn't be read (or were read before the whole table was kept): read them again from the saved file."""
    # READER: bump it when the reader gets better, so lists still waiting are read again once
    cur.execute("SELECT coalesce((SELECT value FROM pap_inbox_state WHERE key = 'reader'), '0')")
    again = cur.fetchone()[0] != READER
    cur.execute("""SELECT i.id, f.file_name, f.data FROM pap_inbox i JOIN pap_mail_file f ON f.id = i.file_id
                   WHERE (i.tbl IS NULL OR %s) AND i.status IN ('unreadable', 'waiting') ORDER BY i.id LIMIT 50""", (again,))
    n = 0
    for iid, fname, fdata in cur.fetchall():
        try:
            head, out, note, cols, tbl = read_list(fname, bytes(fdata))
        except Exception:
            continue
        if out:
            cur.execute("UPDATE pap_inbox SET head = %s, rows = %s, cols = %s, tbl = %s, note = NULL, status = 'waiting' WHERE id = %s",
                        (json.dumps(head), json.dumps(out), json.dumps(cols), json.dumps(tbl), iid))
            n += 1
        elif note:
            cur.execute("UPDATE pap_inbox SET head = %s, rows = NULL, cols = NULL, tbl = NULL, note = %s, status = 'unreadable' WHERE id = %s",
                        (json.dumps(head) if head else None, note, iid))
    set_state(cur, "reader", READER)
    return n


def connect_db():
    import psycopg
    return psycopg.connect(host=os.environ["DB_HOST"], port=int(os.environ.get("DB_PORT") or 5432), dbname=os.environ["DB_NAME"],
                           user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
                           sslmode=os.environ.get("DB_SSLMODE") or "require", connect_timeout=30)


def set_state(cur, key, value):
    cur.execute("INSERT INTO pap_inbox_state (key, value, updated_at) VALUES (%s, %s, now()) "
                "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()", (key, value))


def allowed(addr):
    """Optional EFT_ALLOWED_SENDERS secret: addresses or @domains, comma separated. Empty = anyone (an owner still approves)."""
    rule = [x.strip().lower() for x in (os.environ.get("EFT_ALLOWED_SENDERS") or "").split(",") if x.strip()]
    a = (addr or "").lower()
    return not rule or any(a == r or (r.startswith("@") and a.endswith(r)) for r in rule)


def main():
    host = (os.environ.get("EFT_IMAP_HOST") or os.environ.get("IMAP_HOST") or "").strip()
    user = (os.environ.get("EFT_IMAP_USER") or "eftupload@hsginc.ca").strip()
    pw = os.environ.get("EFT_IMAP_PASS") or ""
    if not (host and pw):
        say("EFT mail isn't set up yet (add EFT_IMAP_PASS to the repository secrets). Nothing to do.")
        return
    port = int(os.environ.get("EFT_IMAP_PORT") or os.environ.get("IMAP_PORT") or 993)
    days = int(os.environ.get("EFT_IMAP_DAYS") or 3650)   # the whole mailbox the first time; after that only new emails are read

    db = connect_db()
    db.autocommit = True
    cur = db.cursor()
    cur.execute("SELECT to_regclass('public.pap_mail') IS NOT NULL")
    if not cur.fetchone()[0]:
        say("The database isn't ready for EFT mail yet (run RUN SETUP.bat with files 99zz11 and 99zz12). Nothing to do.")
        return

    try:
        box = imaplib.IMAP4_SSL(host, port, ssl_context=ssl.create_default_context(), timeout=60)
        box.login(user, pw)
    except Exception as e:
        why = "Couldn't sign in to the EFT mailbox. Check EFT_IMAP_PASS (and IMAP_HOST) in the GitHub secrets."
        if isinstance(e, (OSError, TimeoutError)) and not isinstance(e, imaplib.IMAP4.error):
            why = "Couldn't reach the mail server. Check IMAP_HOST (and IMAP_PORT, usually 993)."
        set_state(cur, "last_error", why)
        set_state(cur, "last_check", datetime.datetime.now(datetime.timezone.utc).isoformat())
        if QUIET:
            print("::error::" + why, flush=True)
        sys.exit(why)

    try:
        box.select("INBOX", readonly=True)          # read only: nothing in the mailbox changes
        since = (datetime.date.today() - datetime.timedelta(days=days)).strftime("%d-%b-%Y")
        typ, data = box.search(None, "SINCE", since)
        nums = (data[0] or b"").split() if typ == "OK" else []
        new = []
        for i in range(0, len(nums), 100):
            typ, rows = box.fetch(b",".join(nums[i:i + 100]).decode(), "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
            for r in rows or []:
                if isinstance(r, tuple):
                    new.append((r[0].split()[0], email.message_from_bytes(r[1]).get("Message-ID", "").strip()))
        ids = [m for _, m in new if m]
        seen = set()
        if ids:
            cur.execute("SELECT message_id FROM pap_mail WHERE message_id = ANY(%s)", (ids,))
            seen = {x[0] for x in cur.fetchall()}
        emails = lists = 0
        for num, mid in new:
            if mid and mid in seen:
                continue
            typ, rows = box.fetch(num.decode(), "(BODY.PEEK[])")
            raw = next((r[1] for r in rows or [] if isinstance(r, tuple)), None)
            if not raw:
                continue
            msg = email.message_from_bytes(raw)
            if not mid:
                mid = "sha:" + hashlib.sha256(raw).hexdigest()
                cur.execute("SELECT 1 FROM pap_mail WHERE message_id = %s", (mid,))
                if cur.fetchone():
                    continue
            name, addr = parseaddr(hdr(msg.get("From")))
            try:
                when = parsedate_to_datetime(msg.get("Date"))
            except Exception:
                when = None
            subj = hdr(msg.get("Subject"))[:300]
            # keep the whole email and every attachment
            cur.execute("""INSERT INTO pap_mail (message_id, received_at, from_addr, from_name, to_addr, cc_addr, subject, body_text, raw, raw_size)
                           VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT (message_id) DO NOTHING RETURNING id""",
                        (mid, when, addr[:200], name[:200], hdr(msg.get("To"))[:1000], hdr(msg.get("Cc"))[:1000], subj, body_text(msg),
                         raw if len(raw) <= 40 * 1024 * 1024 else None, len(raw)))
            got = cur.fetchone()
            if not got:
                continue
            mail_id, file_ids = got[0], {}
            for fname, mime, fdata in all_files(msg):
                cur.execute("INSERT INTO pap_mail_file (mail_id, file_name, mime, size, data) VALUES (%s, %s, %s, %s, %s) RETURNING id",
                            (mail_id, fname, mime, len(fdata), fdata))
                file_ids.setdefault(fname, cur.fetchone()[0])
            for fname, fdata in files_of(msg):
                which = "other" if re.search(r"\bother\b", f"{subj} {fname}", re.I) else "monthly"
                if not allowed(addr):
                    head, out, note, cols, tbl = None, None, "Not from an allowed sender, so the file wasn't read.", None, None
                else:
                    try:
                        head, out, note, cols, tbl = read_list(fname, fdata)
                    except Exception:
                        head, out, note, cols, tbl = None, None, "The file couldn't be opened (is it a real Excel file, not password-protected?).", None, None
                cur.execute("""INSERT INTO pap_inbox (message_id, received_at, from_addr, from_name, subject, file_name, pap_list, head, rows, note, status, mail_id, file_id, cols, tbl)
                               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING""",
                            (mid, when, addr[:200], name[:200], subj, fname, which,
                             json.dumps(head) if head else None, json.dumps(out) if out else None, note,
                             "waiting" if out else "unreadable", mail_id, file_ids.get(fname),
                             json.dumps(cols) if out else None, json.dumps(tbl) if out else None))
                lists += cur.rowcount
            emails += 1
        cur.execute("SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'pap_inbox' AND column_name = 'tbl')")
        if cur.fetchone()[0]:
            again = reread(cur)
            if again:
                say(f"Read {again} emailed list{'s' if again != 1 else ''} again: now waiting for review.")
        # a short summary for the run page: counts and the column names found (never names, numbers or bank details)
        cur.execute("""SELECT status, count(*), coalesce(sum(jsonb_array_length(rows)), 0),
                              string_agg(DISTINCT coalesce(head::text, '-') || ' / ' || coalesce(note, ''), ' | ')
                       FROM pap_inbox GROUP BY status""")
        for st, n, r, h in cur.fetchall():
            say(f"Lists {st}: {n} file(s), {r} row(s). Columns found / note: {h[:400]}")
        cur.execute("SELECT count(*), count(*) FILTER (WHERE EXISTS (SELECT 1 FROM pap_mail_file f WHERE f.mail_id = m.id)) FROM pap_mail m")
        n, nf = cur.fetchone()
        cur.execute("SELECT string_agg(DISTINCT lower(substring(file_name from '\\.[^.]+$')), ', ') FROM pap_mail_file")
        say(f"Emails kept: {n} ({nf} with attachments; attachment types: {cur.fetchone()[0]})")
        set_state(cur, "last_error", None)
        set_state(cur, "last_check", datetime.datetime.now(datetime.timezone.utc).isoformat())
        say(f"EFT mail checked: {emails} new email{'s' if emails != 1 else ''}, {lists} list{'s' if lists != 1 else ''} waiting for review (all emails kept).")
    finally:
        try:
            box.logout()
        except Exception:
            pass
        db.close()


if __name__ == "__main__":
    main()

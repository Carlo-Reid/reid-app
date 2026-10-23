"""Checks the EFT mailbox (eftupload@hsginc.ca) for PAP / EFT lists sent as Excel (or CSV) attachments.

For each file it finds the customer #, name and phone columns and saves ONLY those three columns in the app's
database. The file itself, bank details and every other column are never saved and never shown in the log.
The list then waits on the Security page until an owner reviews it and clicks Mark: nothing changes on its own.
Which list: Monthly billing, unless the email subject (or file name) says "Other".

Runs on GitHub every 10 minutes (.github/workflows/eft-mail.yml). The mailbox details come from the repository's
secrets (EFT_IMAP_PASS, and IMAP_HOST / IMAP_PORT shared with supplier mail), never from the code. It only reads
the mailbox: nothing is deleted, moved or marked as read.
"""
import os, sys, ssl, time, imaplib, email, hashlib, re, datetime, io, csv, json
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
    """A cell as text, the way Excel shows it (12345.0 -> 12345)."""
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    if isinstance(v, (datetime.datetime, datetime.date)):
        return v.isoformat()[:10]
    return str(v).strip()


def sheets_of(name, data):
    """Every row of every sheet, as lists of text."""
    low = name.lower()
    if low.endswith(".csv"):
        text = data.decode("utf-8-sig", "replace")
        try:
            dialect = csv.Sniffer().sniff(text[:4000], delimiters=",;\t")
        except Exception:
            dialect = csv.excel
        return [[cell(v) for v in r] for r in csv.reader(io.StringIO(text), dialect)]
    if low.endswith(".xls"):
        import xlrd
        wb = xlrd.open_workbook(file_contents=data)
        rows = []
        for sh in wb.sheets():
            for r in range(sh.nrows):
                rows.append([cell(v) for v in sh.row_values(r)])
        return rows
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


def read_list(name, data):
    """The three columns we use (same rules as the Upload button on the Security page). Everything else is dropped here."""
    allrows = sheets_of(name, data)
    hi = next((k for k, r in enumerate(allrows[:25]) if any(re.search(r"customer|name|account|cust", v, re.I) for v in r)), 0)
    head = [v.strip() for v in (allrows[hi] if allrows else [])]
    lc = [h.lower() for h in head]
    # never a bank column: "Account #", transit, institution, branch... are skipped even if they look like a customer #
    bank = tuple(j for j, h in enumerate(lc) if re.search(r"bank|transit|institution|routing|branch|acct|account|iban|swift|card", h)
                 and not re.search(r"customer|cust\b|client|name", h))
    num = guess(lc, [r"^(customer|cust\.?|client)\s*(#|no\.?|num(ber)?|id)$", r"customer ?#|cust.*(no|num|id)|client ?(#|no|num|id)"], bank)
    nm = guess(lc, [r"^(customer|client)?\s*name$", r"^customer$", r"name"], (num,) + bank)
    ph = guess(lc, [r"phone|mobile|cell|tel"], (num, nm) + bank)
    if num < 0 and nm < 0 and ph < 0:
        return None, None, "No customer #, name or phone column was found in the file."
    pick = lambda r, i: (r[i] if 0 <= i < len(r) else "").strip()
    out = []
    for r in allrows[hi + 1:]:
        x = [re.sub(r"[,\s]", "", pick(r, num)), pick(r, nm), pick(r, ph)]
        if any(x):
            out.append(x)
    names = [head[i] if i >= 0 else None for i in (num, nm, ph)]
    if not out:
        return names, [], "The file has no customer rows."
    return names, out, None


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
    days = int(os.environ.get("IMAP_DAYS") or 30)

    db = connect_db()
    db.autocommit = True
    cur = db.cursor()
    cur.execute("SELECT to_regclass('public.pap_inbox') IS NOT NULL")
    if not cur.fetchone()[0]:
        say("The database isn't ready for EFT mail yet (run RUN SETUP.bat with file 99zz11). Nothing to do.")
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
            cur.execute("SELECT message_id FROM pap_inbox_seen WHERE message_id = ANY(%s)", (ids,))
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
                cur.execute("SELECT 1 FROM pap_inbox_seen WHERE message_id = %s", (mid,))
                if cur.fetchone():
                    continue
            name, addr = parseaddr(hdr(msg.get("From")))
            try:
                when = parsedate_to_datetime(msg.get("Date"))
            except Exception:
                when = None
            subj = hdr(msg.get("Subject"))[:300]
            for fname, fdata in files_of(msg):
                which = "other" if re.search(r"\bother\b", f"{subj} {fname}", re.I) else "monthly"
                if not allowed(addr):
                    head, out, note = None, None, "Not from an allowed sender, so the file wasn't read."
                else:
                    try:
                        head, out, note = read_list(fname, fdata)
                    except Exception:
                        head, out, note = None, None, "The file couldn't be opened (is it a real Excel file, not password-protected?)."
                cur.execute("""INSERT INTO pap_inbox (message_id, received_at, from_addr, from_name, subject, file_name, pap_list, head, rows, note, status)
                               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING""",
                            (mid, when, addr[:200], name[:200], subj, fname, which,
                             json.dumps(head) if head else None, json.dumps(out) if out else None, note,
                             "waiting" if out else "unreadable"))
                lists += cur.rowcount
            cur.execute("INSERT INTO pap_inbox_seen (message_id) VALUES (%s) ON CONFLICT DO NOTHING", (mid,))
            emails += 1
        set_state(cur, "last_error", None)
        set_state(cur, "last_check", datetime.datetime.now(datetime.timezone.utc).isoformat())
        say(f"EFT mail checked: {emails} new email{'s' if emails != 1 else ''}, {lists} list{'s' if lists != 1 else ''} waiting for review.")
    finally:
        try:
            box.logout()
        except Exception:
            pass
        db.close()


if __name__ == "__main__":
    main()

"""Checks the supplier invoice mailbox (supplierpo@hsginc.ca) and saves the invoice attachments in the app's database.
The app then reads them and puts new costs / new items into the price book approvals (nothing changes until approved).

Runs on GitHub every 10 minutes (.github/workflows/supplier-mail.yml). The mailbox details come from the repository's
secrets (IMAP_HOST, IMAP_USER, IMAP_PASS, optional IMAP_PORT), never from the code. It only reads the mailbox:
nothing is deleted, moved or marked as read. The run log never shows who wrote or what's in an email.
"""
import os, sys, ssl, time, imaplib, email, hashlib, re, datetime, shutil, subprocess, tempfile
from email.header import decode_header, make_header
from email.utils import parseaddr, parsedate_to_datetime

QUIET = bool(os.environ.get("GITHUB_ACTIONS"))
KEEP = (".pdf", ".xlsx", ".xlsm", ".xls", ".csv", ".docx", ".doc")
MAX_FILE = 15 * 1024 * 1024


def say(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)
    if QUIET:
        print("::notice title=Supplier mail::" + msg, flush=True)   # shows on the run's summary page (counts only, never email details)


def hdr(v):
    try:
        return str(make_header(decode_header(v or ""))).strip()
    except Exception:
        return (v or "").strip()


def body_text(msg):
    """The words of the email (for forwarded emails this includes the supplier's From: line)."""
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
    t = "\n".join(plain) if plain else re.sub(r"<[^>]+>", " ", " ".join(html))
    return re.sub(r"[ \t\r\f\v]+", " ", t).strip()[:6000]


def files_of(msg):
    out = []
    for part in msg.walk():
        if part.is_multipart():
            continue
        name = hdr(part.get_filename() or "")
        if not name or not name.lower().endswith(KEEP):
            continue
        data = part.get_payload(decode=True) or b""
        if not data or len(data) > MAX_FILE:
            continue
        out.append((name[:200], part.get_content_type(), data))
    return out


def ocr_pdf(data):
    """The words on a scanned PDF (a photocopier scan has pictures, not text), page by page."""
    if not (shutil.which("pdftoppm") and shutil.which("tesseract")):
        if QUIET:   # on GitHub: add the two tools (about half a minute, only when a scanned invoice comes in)
            env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
            subprocess.run("sudo apt-get update -qq >/dev/null 2>&1; sudo apt-get install -y -qq tesseract-ocr poppler-utils >/dev/null 2>&1", shell=True, env=env)
        if not (shutil.which("pdftoppm") and shutil.which("tesseract")):
            return None
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "in.pdf")
        open(src, "wb").write(data)
        if shutil.which("pdftotext"):   # it has real words after all: nothing to read off pictures
            t = subprocess.run(["pdftotext", "-l", "3", src, "-"], capture_output=True, timeout=60).stdout.decode("utf-8", "replace")
            if len(re.sub(r"\s", "", t)) >= 40:
                return ""
        subprocess.run(["pdftoppm", "-r", "300", "-gray", "-png", "-l", "8", src, os.path.join(d, "p")], capture_output=True, timeout=180)
        pages = []
        for f in sorted(x for x in os.listdir(d) if x.startswith("p") and x.endswith(".png")):
            pages.append(ocr_page(os.path.join(d, f)))
        return "\n\f\n".join(pages) + "\n" + OCR_MARK


OCR_MARK = "[read v2]"   # pages read the way below (turned the right way up first)
WORDS = re.compile(r"\b(invoice|order|total|qty|quantity|ship|sold|date|price|amount|customer|terms|description|phone|tax|hst|gst|unit|each|subtotal|picking|packing|account|branch)\b", re.I)


def ocr_score(t):
    """How much a page reads like a real page: known invoice words and plain long words, minus junk."""
    words = re.findall(r"[A-Za-z]{4,}", t)
    return len(WORDS.findall(t)) * 5 + len(words) - len(re.findall(r"[^\w\s.,:;/$#()&%'\"-]", t))


def ocr_page(img):
    """The words on one page. A page scanned sideways or upside down is turned the right way first."""
    read = lambda f: subprocess.run(["tesseract", f, "stdout", "--psm", "6"], capture_output=True, timeout=180).stdout.decode("utf-8", "replace")
    first = read(img)
    if ocr_score(first) >= 60:
        return first
    try:
        from PIL import Image
    except ImportError:
        return first
    best, best_score = first, ocr_score(first)
    # tesseract can say which way is up; otherwise try each turn
    turns = [90, 180, 270]
    osd = subprocess.run(["tesseract", img, "stdout", "--psm", "0"], capture_output=True, timeout=120).stdout.decode("utf-8", "replace")
    m = re.search(r"Rotate:\s*(\d+)", osd)
    if m and int(m.group(1)) in turns:
        turns.remove(int(m.group(1))); turns.insert(0, int(m.group(1)))
    for deg in turns:
        out = img[:-4] + f"_r{deg}.png"
        Image.open(img).rotate(-deg, expand=True).save(out)
        t = read(out)
        if ocr_score(t) > best_score:
            best, best_score = t, ocr_score(t)
        if best_score >= 60:
            break
    return best


def read_scans(cur):
    """Scanned PDFs (no words inside) get their words read, then the app reads them again."""
    # new scans, and scans read before pages were turned the right way up that came out as junk
    cur.execute("""SELECT id, data FROM supplier_mail
                   WHERE (ocr_text IS NULL OR (status IN ('needs_supplier', 'unread', 'error') AND position(%s IN ocr_text) = 0
                          AND ocr_text !~* '(invoice|order|total|qty|ship|sold|date|price|amount)'))
                     AND data IS NOT NULL AND status IN ('new', 'unread', 'error', 'needs_supplier')
                     AND (lower(coalesce(file_name, '')) LIKE '%%.pdf' OR mime ILIKE '%%pdf%%')
                     AND position('\\x2f466f6e74'::bytea IN data) = 0
                     AND coalesce(received_at, created_at) > now() - interval '60 days'
                   ORDER BY id LIMIT 20""", (OCR_MARK,))
    n = 0
    for mid, data in cur.fetchall():
        text = ocr_pdf(bytes(data))
        if text is None:
            say("Couldn't read the scanned invoices this time (the reading tool didn't install).")
            return 0
        if text:
            cur.execute("UPDATE supplier_mail SET ocr_text = %s, status = 'new', result = NULL WHERE id = %s", (text[:200000], mid))
            n += 1
        else:
            cur.execute("UPDATE supplier_mail SET ocr_text = '' WHERE id = %s", (mid,))
    return n


def connect_db():
    import psycopg
    return psycopg.connect(host=os.environ["DB_HOST"], port=int(os.environ.get("DB_PORT") or 5432), dbname=os.environ["DB_NAME"],
                           user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
                           sslmode=os.environ.get("DB_SSLMODE") or "require", connect_timeout=30)


def set_state(cur, key, value):
    cur.execute("INSERT INTO supplier_mail_state (key, value, updated_at) VALUES (%s, %s, now()) "
                "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()", (key, value))


def main():
    host, user, pw = os.environ.get("IMAP_HOST", "").strip(), os.environ.get("IMAP_USER", "").strip(), os.environ.get("IMAP_PASS", "")
    if not (host and user and pw):
        say("Supplier mail isn't set up yet (add IMAP_HOST, IMAP_USER and IMAP_PASS to the repository secrets). Nothing to do.")
        return
    port = int(os.environ.get("IMAP_PORT") or 993)
    days = int(os.environ.get("IMAP_DAYS") or 30)
    use_ssl = (os.environ.get("IMAP_SSL") or "1") != "0"
    folder = os.environ.get("IMAP_FOLDER") or "INBOX"

    db = connect_db()
    db.autocommit = True
    cur = db.cursor()
    cur.execute("SELECT to_regclass('public.supplier_mail') IS NOT NULL")
    if not cur.fetchone()[0]:
        say("The database isn't ready for supplier mail yet (run RUN SETUP.bat with file 92). Nothing to do.")
        return

    try:
        box = imaplib.IMAP4_SSL(host, port, ssl_context=ssl.create_default_context(), timeout=60) if use_ssl else imaplib.IMAP4(host, port, timeout=60)
        box.login(user, pw)
    except Exception as e:
        why = "Couldn't sign in to the supplier mailbox. Check IMAP_HOST, IMAP_USER and IMAP_PASS in the GitHub secrets."
        if isinstance(e, (OSError, TimeoutError)) and not isinstance(e, imaplib.IMAP4.error):
            why = "Couldn't reach the mail server. Check IMAP_HOST (and IMAP_PORT, usually 993)."
        set_state(cur, "last_error", why)
        set_state(cur, "last_check", datetime.datetime.now(datetime.timezone.utc).isoformat())
        if QUIET:
            print("::error::" + why, flush=True)
        sys.exit(why)

    try:
        box.select(folder, readonly=True)          # read only: nothing in the mailbox changes
        since = (datetime.date.today() - datetime.timedelta(days=days)).strftime("%d-%b-%Y")
        typ, data = box.search(None, "SINCE", since)
        nums = (data[0] or b"").split() if typ == "OK" else []
        # which ones are new: look at the Message-ID only, then fetch just those
        new = []
        for i in range(0, len(nums), 100):
            chunk = b",".join(nums[i:i + 100]).decode()
            typ, rows = box.fetch(chunk, "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
            for r in rows or []:
                if not isinstance(r, tuple):
                    continue
                num = r[0].split()[0]
                mid = email.message_from_bytes(r[1]).get("Message-ID", "").strip()
                new.append((num, mid))
        ids = [m for _, m in new if m]
        seen = set()
        if ids:
            cur.execute("SELECT message_id FROM supplier_mail_seen WHERE message_id = ANY(%s)", (ids,))
            seen = {x[0] for x in cur.fetchall()}
        emails = files = 0
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
                cur.execute("SELECT 1 FROM supplier_mail_seen WHERE message_id = %s", (mid,))
                if cur.fetchone():
                    continue
            name, addr = parseaddr(hdr(msg.get("From")))
            try:
                when = parsedate_to_datetime(msg.get("Date"))
            except Exception:
                when = None
            subj, body = hdr(msg.get("Subject"))[:300], body_text(msg)
            got = files_of(msg)
            if got:
                for fname, mime, data in got:
                    cur.execute("""INSERT INTO supplier_mail (message_id, received_at, from_addr, from_name, subject, body_text, file_name, mime, size, sha, data)
                                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING""",
                                (mid, when, addr[:200], name[:200], subj, body, fname, mime, len(data), hashlib.sha256(data).hexdigest(), data))
                    files += cur.rowcount
            else:
                cur.execute("""INSERT INTO supplier_mail (message_id, received_at, from_addr, from_name, subject, body_text, status)
                               VALUES (%s, %s, %s, %s, %s, %s, 'no_file') ON CONFLICT DO NOTHING""", (mid, when, addr[:200], name[:200], subj, body))
            cur.execute("INSERT INTO supplier_mail_seen (message_id) VALUES (%s) ON CONFLICT DO NOTHING", (mid,))
            emails += 1
        cur.execute("SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'supplier_mail' AND column_name = 'ocr_text')")
        scans = read_scans(cur) if cur.fetchone()[0] else 0   # needs setup file 93
        if scans:
            say(f"Read the words on {scans} scanned invoice{'s' if scans != 1 else ''}.")
        set_state(cur, "last_error", None)
        set_state(cur, "last_check", datetime.datetime.now(datetime.timezone.utc).isoformat())
        say(f"Supplier mail checked: {emails} new email{'s' if emails != 1 else ''}, {files} file{'s' if files != 1 else ''} saved.")
    finally:
        try:
            box.logout()
        except Exception:
            pass
        db.close()


if __name__ == "__main__":
    main()

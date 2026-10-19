"""Checks the supplier invoice mailbox (supplierpo@hsginc.ca) and saves the invoice attachments in the app's database.
The app then reads them and puts new costs / new items into the price book approvals (nothing changes until approved).

Runs on GitHub every 10 minutes (.github/workflows/supplier-mail.yml). The mailbox details come from the repository's
secrets (IMAP_HOST, IMAP_USER, IMAP_PASS, optional IMAP_PORT), never from the code. It only reads the mailbox:
nothing is deleted, moved or marked as read. The run log never shows who wrote or what's in an email.
"""
import os, sys, ssl, time, imaplib, email, hashlib, re, datetime
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

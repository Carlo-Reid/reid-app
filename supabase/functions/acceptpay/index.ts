// Supabase Edge Function: acceptpay   ("Verify JWT" is OFF: the database's own twice-a-day check calls it with a secret key;
// everyone else must be a signed-in owner, checked below.)
// The app's READ-ONLY connection to AcceptPay (Accept/Pay Global EFT API, guide v1.0.14). Security page → PAP payments → Settings.
//   { action: "test" }                  → signs in to AcceptPay and says which system answered (live or test), the currency, when the key expires
//   { action: "fetch", since? }         → brings in the transactions whose bank answer is new since that day (default: a few days before the last look)
// It only ever uses GET (and the Login POST). It never creates, changes, voids or stops anything at AcceptPay.
// The username and key live in the database vault and are never sent to the browser. See sync/extra/320_acceptpay.sql.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const HOSTS: Record<string, string> = { live: "https://api.acceptpayglobal.com", test: "https://apiuat.acceptpayglobal.com" };
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });
const timed = async (url: string, ms: number, init: RequestInit = {}) => { const c = new AbortController(); const t = setTimeout(() => c.abort(), ms); try { return await fetch(url, { ...init, signal: c.signal }); } finally { clearTimeout(t); } };
type Sec = { username?: string; api_key?: string; cron_key?: string; env?: string | null; auto?: boolean; last_since?: string | null };
type Rec = Record<string, unknown>;

// the bank's answers, in the words the emailed report uses (the live list from AcceptPay wins when it answers)
const RESP: Record<string, string> = { AA: "Approved", PD: "Pending", "900": "900 Edit Reject", "901": "901 NSF", "902": "902 Account not Found", "903": "903 Payment Stopped/Recalled",
  "905": "905 Account Closed", "907": "907 No Debit Allowed", "908": "908 Funds Not Cleared", "909": "909 Currency/Account Mismatch", "910": "910 Deceased", "911": "911 Account Frozen",
  "912": "912 Invalid/Incorrect Account No.", "914": "914 Incorrect Payor/Payee Name", "915": "915 Refused - No PAD Agreement Existed", "916": "916 Refused by Payor - PAD not drawn in accordance to agreement",
  "917": "917 Refused by Payor - PAD agreement revoked", "918": "918 Refused by Payor - No Confirmation/Pre-Notification", "919": "919 Refused by Payor - PAD not drawn in accordance to agreement",
  "920": "920 Refused by Payor - PAD agreement revoked", "921": "921 Refused by Payor - No Pre-Notification", "922": "922 Refused by Payee - Customer Initiated Return", "996": "996 Chargeback" };
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const day = (v: unknown) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(v ?? "")); return m ? `${m[3]}-${MON[Number(m[2]) - 1]}-${m[1]}` : ""; };   // 08-Sep-2026, as in the emailed file
const iso = (d: Date) => d.toISOString().slice(0, 10);
const txt = (v: unknown, n = 200) => v == null ? "" : String(v).trim().slice(0, n);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "post_only" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!, auth = req.headers.get("Authorization") ?? "";
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  let body: { action?: string; since?: string; auto?: boolean } = {};
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const sec = ((await admin.rpc("_acceptpay_secrets")).data ?? {}) as Sec;

  // who is asking: the database's own check (secret key), or a signed-in owner
  const cronKey = req.headers.get("x-cron-key") ?? "";
  const isCron = !!cronKey && !!sec.cron_key && cronKey.length === sec.cron_key.length && cronKey === sec.cron_key;
  if (!isCron) {
    if (!auth) return json({ error: "not_allowed" }, 401);
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
    const who = await asUser.rpc("acceptpay_allowed");
    if (who.error || !who.data) return json({ error: "not_allowed" });
  } else if (body.action !== "fetch" || !sec.auto) return json({ skipped: true });
  if (!sec.username || !sec.api_key) return json({ need_keys: true });

  // sign in: AcceptPay gives a key that is good for 4 hours; one is asked for each time this runs. `token` is the whole Authorization value.
  const login = async (env: string): Promise<{ token?: string; error?: string; status?: number }> => {
    try {
      const r = await timed(HOSTS[env] + "/eft/User/Login", 20000, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
        body: new URLSearchParams({ Username: sec.username!, Password: sec.api_key! }).toString() });
      const j = await r.json().catch(() => ({})) as Rec;
      // AcceptPay's guide shows two ways to prove who we are on each call: the token from Login ("Bearer"), or the username and key
      // themselves ("Basic"). Try each on a small harmless call and keep the first one AcceptPay accepts.
      const enc = (t: string) => btoa(String.fromCharCode(...new TextEncoder().encode(t)));
      const tok = r.ok && j.Success === true && j.Token ? String(j.Token) : "";
      const ways: [string, string][] = [...(tok ? [["token", "Bearer " + tok]] as [string, string][] : []), ["key", "Basic " + enc(sec.username + ":" + sec.api_key)],
        ...(tok ? [["token2", "Basic " + enc(sec.username + ":" + tok)], ["bare", tok]] as [string, string][] : [])];
      const said: string[] = [];
      for (const [name, val] of ways) {
        const b = await timed(HOSTS[env] + "/eft/enumerations/serverinfo", 20000, { headers: { Authorization: val, Accept: "application/json" } });
        if (b.ok) { way = name; return { token: val }; }
        said.push(name + " " + b.status);
      }
      return { status: r.status, error: (tok ? "AcceptPay signed us in but then refused every call" : "AcceptPay did not accept the username and key") + " (sign-in answered " + r.status + "; " + said.join(", ") + ")." };
    } catch { return { error: "AcceptPay did not answer." }; }
  };
  let way = "";   // which of the ways AcceptPay accepted (a word, never the key)
  const signIn = async (): Promise<{ env?: string; token?: string; error?: string; tried?: string[] }> => {
    const order = sec.env === "test" ? ["test", "live"] : ["live", "test"], tried: string[] = []; let last = "";
    for (const env of order) { const t = await login(env); if (t.token) return { env, token: t.token }; tried.push((env === "live" ? "live system" : "test system") + ": " + t.error); last = /signed us in/.test(t.error ?? "") && !/signed us in/.test(last) ? "AcceptPay signed us in, but then refused the calls." : (last || "AcceptPay did not accept the username and key."); }
    return { error: last || "AcceptPay did not answer.", tried };
  };
  const get = async (env: string, token: string, path: string, ms = 20000): Promise<{ ok: boolean; status: number; data: unknown }> => {
    try { const r = await timed(HOSTS[env] + path, ms, { headers: { Authorization: token, Accept: "application/json" } });
      return { ok: r.ok, status: r.status, data: await r.json().catch(() => null) }; } catch { return { ok: false, status: 0, data: null }; }
  };
  const keysOf = (o: unknown) => o && typeof o === "object" ? Object.keys(o as Rec).slice(0, 40) : [];
  // the list of changes since a day, 100 at a time
  const updates = async (env: string, token: string, since: string, maxPages = 60) => {
    const all: Rec[] = []; let pages = 0, status = 200;
    for (let p = 1; p <= maxPages; p++) {
      const r = await get(env, token, `/eft/updates/transactions/${since}/${p}`, 30000); status = r.status;
      if (!r.ok || !Array.isArray(r.data)) { if (p === 1) { const one = await get(env, token, `/eft/updates/transactions/${since}`, 45000); status = one.status; if (one.ok && Array.isArray(one.data)) all.push(...one.data as Rec[]); else return { error: "AcceptPay would not give the list of changes (" + status + ").", list: all, pages }; } break; }
      const list = r.data as Rec[]; pages++; all.push(...list); if (list.length < 100) break;
    }
    return { list: all, pages };
  };

  const s = await signIn();
  if (!s.token || !s.env) {
    const note = s.error + (s.tried?.length ? " (" + s.tried.join("; ") + ")" : "");
    await admin.rpc("_acceptpay_note", { p: body.action === "test" ? { test_ok: false, test_note: note, error: note } : { error: note, ...(isCron ? { auto_ran: true } : {}) } });
    return json({ error: "acceptpay", message: s.error, tried: s.tried });
  }
  const env = s.env, token = s.token;

  if (body.action === "test") {
    const [acc, srv] = await Promise.all([get(env, token, "/eft/Account"), get(env, token, "/eft/enumerations/serverinfo")]);
    const a = (acc.data ?? {}) as Rec, sv = (srv.data ?? {}) as Rec, since = iso(new Date(Date.now() - 7 * 864e5));
    const up = await updates(env, token, since, 3);
    let detailKeys: string[] = [], detailStatus = 0;
    const first = up.list.find(x => x && x.Id != null);
    if (first) { const d = await get(env, token, "/eft/transactions/" + encodeURIComponent(String(first.Id))); detailStatus = d.status; detailKeys = keysOf(d.data); }
    const account = { currency: txt(a.Currency, 10) || null, key_expires: txt(a.ApiKeyExpirationDate, 30) || null, mids: Array.isArray(a.MID) ? a.MID.length : (a.MID != null ? 1 : 0), version: txt(sv.Version, 40) || null, zone: txt(sv.TimeZone, 80) || null };
    const note = "Signed in to the " + (env === "live" ? "live" : "TEST") + " system." + (up.error ? " " + up.error : ` ${up.list.length}${up.list.length >= 300 ? " or more" : ""} changes in the last 7 days.`);
    await admin.rpc("_acceptpay_note", { p: { env, test_ok: !up.error, test_note: note, account, error: up.error ?? "",
      probe: { at: new Date().toISOString(), env, way, account_status: acc.status, account_keys: keysOf(acc.data), server_status: srv.status, updates_pages: up.pages, updates_n: up.list.length, update_keys: keysOf(up.list[0]), detail_status: detailStatus, detail_keys: detailKeys } } });
    return json({ ok: !up.error, env, account, changes_7d: up.list.length, message: up.error ?? null });
  }

  if (body.action === "fetch") {
    const started = Date.now(), today = iso(new Date());
    let since = /^\d{4}-\d{2}-\d{2}$/.test(String(body.since ?? "")) && !isCron ? String(body.since) : "";
    if (!since) since = sec.last_since ? iso(new Date(new Date(sec.last_since + "T12:00:00Z").getTime() - 5 * 864e5)) : iso(new Date(Date.now() - 14 * 864e5));
    if (since > today) since = today;
    const fail = async (m: string) => { await admin.rpc("_acceptpay_note", { p: { env, error: m, ...(isCron ? { auto_ran: true } : {}) } }); return json({ error: "acceptpay", message: m }); };
    const up = await updates(env, token, since);
    if (up.error) return await fail(up.error);
    // only transactions the bank has answered (approved, NSF, closed...). Pending ones come later, when they are answered.
    const answered = up.list.filter(x => x && x.Id != null && txt(x.Response) && txt(x.Response).toUpperCase() !== "PD");
    const fresh = ((await admin.rpc("_acceptpay_new", { p: answered.map(x => ({ Id: String(x.Id), Response: txt(x.Response), Status: txt(x.Status) })) })).data ?? []) as number[];
    if (!fresh.length) { await admin.rpc("_acceptpay_done", { p_since: today, p_note: `Looked from ${since}: ${up.list.length} changes at AcceptPay, nothing new to bring in.` }); if (isCron) await admin.rpc("_acceptpay_note", { p: { auto_ran: true } });
      return json({ ok: true, env, since, seen: up.list.length, added: 0, more: false }); }

    // names (the report has First Name and Last Name; a transaction only has the customer's AcceptPay number) and the answers' words
    const [cu, en] = await Promise.all([get(env, token, "/eft/customers", 45000), get(env, token, "/eft/enumerations/response")]);
    const names = new Map<string, [string, string]>();
    if (Array.isArray(cu.data)) for (const c of cu.data as Rec[]) if (c && c.Id != null) names.set(String(c.Id), [txt(c.FirstName, 80), txt(c.LastName, 80)]);
    const words: Record<string, string> = { ...RESP };
    if (Array.isArray(en.data)) for (const e of en.data as Rec[]) { const c = txt(e?.Code, 10), d = txt(e?.Description, 120); if (c && d && c !== "AA") words[c] = d; }

    const todo = fresh.slice(0, 400), rows: { id: string; response: string; status: string; row: string[] }[] = []; let bad = 0, i = 0;
    const work = async () => { while (i < todo.length && Date.now() - started < 105000) {
      const id = String(todo[i++]); const d = await get(env, token, "/eft/transactions/" + id, 15000); const t = d.data as Rec | null;
      if (!d.ok || !t || t.Id == null) { bad++; continue; }
      const code = txt(t.Response, 10), nm = names.get(String(t.CustomerId ?? "")) ?? ["", ""];
      if (!code || code.toUpperCase() === "PD") continue;
      rows.push({ id, response: code, status: txt(t.Status, 10), row: [id, day(t.ProcessDate), day(t.ResponseDate), txt(t.TransactionType, 10), nm[0], nm[1],
        code.toUpperCase() === "AA" ? "Approved" : (words[code] ?? code), t.Amount == null ? "" : Number(t.Amount).toFixed(2), code.toUpperCase() === "AA" ? "AA" : "", txt(t.Reference, 100)] });
    } };
    await Promise.all(Array.from({ length: 6 }, work));
    let added = 0, inbox: number | null = null;
    if (rows.length) { const r = await admin.rpc("_acceptpay_file_in", { p_rows: rows, p_since: since }); if (r.error) return await fail("The rows were read but could not be saved."); added = Number((r.data as Rec)?.added) || 0; inbox = ((r.data as Rec)?.inbox_id as number) ?? null; }
    const left = fresh.length - i + bad, more = left > 0 && rows.length > 0;
    if (!rows.length && bad) return await fail("AcceptPay listed changes but would not give their details. Nothing was brought in.");
    if (!more) await admin.rpc("_acceptpay_done", { p_since: today, p_note: `Looked from ${since}: ${added} transaction${added === 1 ? "" : "s"} brought in.` + (left > 0 ? ` ${left} could not be read; they are tried again next time.` : "") });
    if (isCron) await admin.rpc("_acceptpay_note", { p: { auto_ran: true } });
    return json({ ok: true, env, since, seen: up.list.length, added, more, left, inbox_id: inbox, no_names: !names.size });
  }
  return json({ error: "bad_request" }, 400);
});

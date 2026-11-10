// Supabase Edge Function: podium   (keep "Verify JWT" ON: only signed-in owners use it)
// The app's connection to Podium (Settings → Podium). Podium uses OAuth: an owner approves the app once on Podium's own page.
//   { action: "start" }               → the Podium address to send the owner to, to approve the connection
//   { action: "finish", code, state } → trades Podium's one-time code for the keys, saves them in the vault, lists the locations
//   { action: "test" }                → asks Podium for the locations, to prove the connection still works
//   { action: "send", customer_id, phone, body } → office people: one text to a customer through Podium (test mode sends it to the test number instead)
//   { action: "live_on" } / { action: "live_off" } → owners: ask Podium to tell the podium-hook function about every call and text as it happens; live_on also catches up on recent calls
//   { action: "probe" }               → tries the addresses where calls / recordings might be and says which ones answer (no customer data is returned: only yes/no and field names)
// The Client ID / Secret and the tokens live in the database vault; they are never sent to the browser. See sync/extra/246_podium.sql.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const REDIRECT = "https://reid-app.pages.dev/";   // must be exactly the Redirect URL typed in the Podium developer page
const SCOPES = "read_locations read_organizations read_contacts write_contacts read_messages write_messages read_phones";   // read_phones added Nov 10 to look for calls and recordings
const API = "https://api.podium.com";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });
const timed = async (url: string, ms: number, init: RequestInit = {}) => { const c = new AbortController(); const t = setTimeout(() => c.abort(), ms); try { return await fetch(url, { ...init, signal: c.signal }); } finally { clearTimeout(t); } };
type Sec = { client_id?: string; client_secret?: string; refresh_token?: string; access_token?: string; expires?: string | null };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "post_only" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!, auth = req.headers.get("Authorization") ?? "";
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  let body: { action?: string; code?: string; state?: string; customer_id?: number; phone?: string; body?: string } = {};
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const texter = body.action === "send" ? ((await asUser.rpc("podium_text_who")).data as { user?: number; name?: string; test_to?: string } | null) : null;
  const who = body.action === "send" ? { data: texter?.user ?? null, error: null } : await asUser.rpc("podium_allowed");
  if (who.error || !who.data) return json({ error: "not_allowed" });
  const sec = ((await admin.rpc("_podium_secrets")).data ?? {}) as Sec;
  if (!sec.client_id || !sec.client_secret) return json({ need_keys: true });

  // ask Podium for tokens (first time with the one-time code, later with the refresh token)
  const tokens = async (extra: Record<string, string>) => {
    try {
      const r = await timed(API + "/oauth/token", 20000, { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ client_id: sec.client_id, client_secret: sec.client_secret, ...extra }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok || !j.access_token) return { error: String(j.error_description ?? j.error ?? j.message ?? ("Podium said no (" + r.status + ")")).slice(0, 200) };
      const secs = Number(j.expires_in) > 0 ? Number(j.expires_in) : 36000;   // 10 hours
      return { access: String(j.access_token), refresh: j.refresh_token ? String(j.refresh_token) : null, expires: new Date(Date.now() + (secs - 300) * 1000).toISOString() };
    } catch { return { error: "Podium did not answer." }; }
  };
  const locations = async (access: string) => {
    try {
      const r = await timed(API + "/v4/locations?limit=100", 20000, { headers: { Authorization: "Bearer " + access, Accept: "application/json" } });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) return { status: r.status, error: String(j.message ?? j.error ?? ("Podium said no (" + r.status + ")")).slice(0, 200) };
      const list = (Array.isArray(j.data) ? j.data : Array.isArray(j.locations) ? j.locations : Array.isArray(j) ? j : []) as Record<string, unknown>[];
      return { list: list.slice(0, 100).map(l => ({ uid: String(l.uid ?? l.id ?? ""), name: String(l.name ?? l.displayName ?? "").slice(0, 120) })) };
    } catch { return { error: "Podium did not answer." }; }
  };

  // a working key for Podium: the saved one while it is still good, else a new one
  const access = async (): Promise<{ token?: string; error?: string }> => {
    if (sec.access_token && sec.expires && new Date(sec.expires).getTime() > Date.now()) return { token: sec.access_token };
    if (!sec.refresh_token) return { error: "not_connected" };
    const t = await tokens({ grant_type: "refresh_token", refresh_token: sec.refresh_token });
    if ("error" in t) return { error: t.error };
    await admin.rpc("_podium_save", { p_access: t.access, p_refresh: t.refresh, p_expires: t.expires, p_user: null, p_locations: null, p_error: null });
    return { token: t.access };
  };
  const locUid = async () => (((await admin.from("podium_conn").select("locations").eq("id", 1).maybeSingle()).data?.locations ?? []) as { uid?: string }[])[0]?.uid ?? null;
  const last10 = (s: unknown) => String(s ?? "").replace(/\D/g, "").slice(-10);

  if (body.action === "send") {
    const customer = Number(body.customer_id), d = last10(body.phone), text = String(body.body ?? "").replace(/\r/g, "").trim().slice(0, 1500);
    if (!customer || d.length !== 10 || !text) return json({ error: "bad_request" }, 400);
    const chk = (await admin.rpc("_podium_text_check", { p_customer: customer, p_phone: d })).data;
    if (chk !== "ok") return json({ error: chk === "no_texts" ? "no_texts" : "not_theirs" });
    let to = d, testTo: string | null = null;
    if (texter?.test_to) { if (texter.test_to === "none") return json({ error: "test_no_number" }); testTo = texter.test_to; to = testTo; }
    const loc = await locUid(); if (!loc) return json({ error: "no_location" });
    const a = await access(); if (!a.token) return json(a.error === "not_connected" ? { need_connect: true } : { error: "podium", message: a.error });
    const sent = (testTo ? "[TEST: this would go to " + d.replace(/(\d{3})(\d{3})(\d{4})/, "$1-$2-$3") + "] " : "") + text;
    let r: Response, j: Record<string, unknown> = {};
    try { r = await timed(API + "/v4/messages", 20000, { method: "POST", headers: { Authorization: "Bearer " + a.token, "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ channel: { type: "phone", identifier: "+1" + to }, body: sent, locationUid: loc, ...(texter?.name ? { senderName: texter.name } : {}) }) });
      j = await r.json().catch(() => ({})); } catch { return json({ error: "podium", message: "Podium did not answer." }); }
    if (!r.ok) return json({ error: "podium", message: String(j.message ?? j.error ?? ("Podium said no (" + r.status + ")")).slice(0, 300) });
    const m = (j.data && typeof j.data === "object" ? j.data : j) as Record<string, unknown>;
    await admin.rpc("_podium_msg_in", { p_dir: "out", p_status: "sent", p: { uid: m.uid ?? null, body: sent, phone: d, createdAt: new Date().toISOString() }, p_sent_by: texter?.user ?? null, p_test_to: testTo });
    return json({ sent: true, test_to: testTo });
  }

  if (body.action === "live_on" || body.action === "live_off") {
    const a = await access(); if (!a.token) return json(a.error === "not_connected" ? { need_connect: true } : { error: "podium", message: a.error });
    const H = { Authorization: "Bearer " + a.token, "Content-Type": "application/json", Accept: "application/json" };
    const old = (await admin.from("podium_conn").select("webhook_uid").eq("id", 1).maybeSingle()).data?.webhook_uid as string | null;
    if (old) { try { await timed(API + "/v4/webhooks/" + encodeURIComponent(old), 15000, { method: "DELETE", headers: H }); } catch { /* gone already */ } await admin.rpc("_podium_hook_set", { p_uid: null }); }
    if (body.action === "live_off") return json({ on: false });
    const loc = await locUid(); if (!loc) return json({ error: "no_location" });
    const secret = (await admin.rpc("_podium_hook_secret")).data as string;
    const hookUrl = url.replace(/\/$/, "") + "/functions/v1/podium-hook";
    const sets = [["call.completed", "call.missed", "call.received", "call.voicemail_left", "message.failed", "message.received", "message.sent"],
      ["message.failed", "message.received", "message.sent"], ["call.completed", "call.missed", "call.received", "call.voicemail_left"]];
    let uid: string | null = null, got: string[] = [], why = "";
    for (const ev of sets) {
      try { const r = await timed(API + "/v4/webhooks", 20000, { method: "POST", headers: H, body: JSON.stringify({ url: hookUrl, eventTypes: ev, locationUid: loc, secret }) });
        const j = await r.json().catch(() => ({})) as Record<string, unknown>; const w = (j.data && typeof j.data === "object" ? j.data : j) as Record<string, unknown>;
        if (r.ok && w.uid) { uid = String(w.uid); got = ev; await admin.rpc("_podium_hook_note", { p: { setup: true, events: ev, keys: Object.keys(w).slice(0, 30), disabled: w.disabledAt ?? w.disabled ?? null } }); break; }
        why = String(j.message ?? j.error ?? ("Podium said no (" + r.status + ")")).slice(0, 300);
      } catch { why = "Podium did not answer."; }
    }
    if (!uid) { await admin.rpc("_podium_hook_note", { p: { setup: false, message: why } }); return json({ error: "podium", message: why }); }
    await admin.rpc("_podium_hook_set", { p_uid: uid });
    // catch up: the calls Podium already has (newest first, up to 1,000)
    let n = 0, cursor = "", pages = 0;
    try { while (pages++ < 10) {
        const r = await timed(API + "/v4/calls?limit=100" + (cursor ? "&cursor=" + encodeURIComponent(cursor) : ""), 20000, { headers: H }); if (!r.ok) break;
        const j = await r.json().catch(() => null) as { data?: unknown[]; metadata?: { nextCursor?: string } } | null; const list = j?.data ?? []; if (!list.length) break;
        n += Number((await admin.rpc("_podium_calls_in", { p: list })).data) || 0;
        cursor = j?.metadata?.nextCursor ?? ""; if (!cursor) break; } } catch { /* what came in stays */ }
    return json({ on: true, events: got, calls: n });
  }

  if (body.action === "start") {
    const st = await admin.rpc("_podium_state_new", { p_user: who.data });
    if (st.error || !st.data) return json({ error: "failed", message: "I could not start." });
    return json({ url: API + "/oauth/authorize?client_id=" + encodeURIComponent(sec.client_id) + "&redirect_uri=" + encodeURIComponent(REDIRECT)
      + "&scope=" + encodeURIComponent(SCOPES) + "&state=" + encodeURIComponent(String(st.data)), redirect: REDIRECT, scopes: SCOPES });
  }

  if (body.action === "finish") {
    const code = String(body.code ?? "").slice(0, 2000), state = String(body.state ?? "").slice(0, 200);
    if (!code || !state) return json({ error: "bad_request" }, 400);
    const ok = await admin.rpc("_podium_state_use", { p_state: state, p_user: who.data });
    if (ok.error || !ok.data) return json({ error: "old", message: "That took too long, or it was started by someone else. Press Connect to Podium again." });
    const t = await tokens({ grant_type: "authorization_code", code, redirect_uri: REDIRECT });
    if ("error" in t) return json({ error: "podium", message: t.error });
    if (!t.refresh) return json({ error: "podium", message: "Podium did not give me a key to stay connected." });
    const loc = await locations(t.access);
    await admin.rpc("_podium_save", { p_access: t.access, p_refresh: t.refresh, p_expires: t.expires, p_user: who.data, p_locations: loc.list ?? null, p_error: loc.error ?? null });
    return json({ connected: true, locations: loc.list ?? [], note: loc.error ?? null });
  }

  if (body.action === "probe") {
    if (!sec.refresh_token) return json({ need_connect: true });
    const t = await tokens({ grant_type: "refresh_token", refresh_token: sec.refresh_token });
    if ("error" in t) return json({ error: "podium", message: t.error });
    await admin.rpc("_podium_save", { p_access: t.access, p_refresh: t.refresh, p_expires: t.expires, p_user: null, p_locations: null, p_error: null });
    const loc = ((await admin.from("podium_conn").select("locations").eq("id", 1).maybeSingle()).data?.locations ?? []) as { uid?: string }[];
    const L = loc[0]?.uid ? "?locationUid=" + encodeURIComponent(loc[0].uid) + "&limit=2" : "?limit=2";
    const paths = ["phones", "phone_numbers", "phone-numbers", "calls", "phone_calls", "phones/calls", "call_recordings", "recordings", "voicemails", "conversations", "messages", "users"];
    const keysOf = (o: unknown): string[] => o && typeof o === "object" && !Array.isArray(o) ? Object.keys(o as Record<string, unknown>).slice(0, 40) : [];
    const out: Record<string, unknown>[] = [];
    for (const p of paths) for (const q of [L, "?limit=2"]) {
      try { const r = await timed(API + "/v4/" + p + q, 12000, { headers: { Authorization: "Bearer " + t.access, Accept: "application/json" } });
        const j = await r.json().catch(() => null) as Record<string, unknown> | null;
        const list = j && Array.isArray(j.data) ? j.data as unknown[] : Array.isArray(j) ? j as unknown[] : null;
        out.push({ path: p, with_location: q === L && q !== "?limit=2", status: r.status, keys: keysOf(j), n: list ? list.length : null, item_keys: list && list.length ? keysOf(list[0]) : [],
          message: !r.ok && j ? String(j.message ?? j.error ?? "").slice(0, 160) : "" });
        if (r.ok || q === "?limit=2" || L === "?limit=2") break;
      } catch { out.push({ path: p, status: 0, message: "no answer" }); break; }
    }
    // calls answered on Nov 10: look closer at one call for where its recording is (field names and masked addresses only, no customer data)
    try {
      const H = { Authorization: "Bearer " + t.access, Accept: "application/json" };
      const mask = (v: string) => v.replace(/[0-9a-f]{8}-[0-9a-f-]{27,}/gi, "{uid}").replace(/\+?\d{7,}/g, "{n}").replace(/\?.*$/, "?…").slice(0, 160);
      const deep = (o: unknown, pre = "", d = 0, acc: Record<string, string> = {}): Record<string, string> => {
        if (o && typeof o === "object" && d < 4) for (const [k, v] of Object.entries(Array.isArray(o) ? (o.length ? { "[0]": o[0] } : {}) : o as Record<string, unknown>)) {
          const key = pre ? pre + "." + k : k;
          if (v && typeof v === "object") deep(v, key, d + 1, acc);
          else acc[key] = v === null ? "null" : typeof v === "string" && /^https?:\/\//.test(v) ? "url " + mask(v) : typeof v; }
        return acc; };
      const lr = await timed(API + "/v4/calls?limit=25", 15000, { headers: H }); const lj = await lr.json().catch(() => null) as { data?: Record<string, unknown>[]; metadata?: unknown } | null;
      const calls = lj?.data ?? [];
      out.push({ path: "calls (list, closer look)", status: lr.status, n: calls.length, metadata_keys: keysOf(lj?.metadata), shape: calls[0] ? deep(calls[0]) : {},
        statuses: [...new Set(calls.map(c => String(c.status)))], directions: [...new Set(calls.map(c => String(c.direction)))], event_types: [...new Set(calls.map(c => String(c.eventType)))],
        with_voicemail: calls.filter(c => c.hasVoicemail).length, voicemail_shape: deep(calls.find(c => c.hasVoicemail)?.voicemail ?? null) });
      const one = calls.find(c => Number(c.durationSeconds) > 20) ?? calls[0];
      if (one?.uid) for (const tail of ["", "/recording", "/recordings", "/audio", "/media", "/transcript", "/transcription"]) {
        const r = await timed(API + "/v4/calls/" + encodeURIComponent(String(one.uid)) + tail, 12000, { headers: H, redirect: "manual" });
        const ct = r.headers.get("content-type") ?? ""; const j = /json/.test(ct) ? await r.json().catch(() => null) : null;
        out.push({ path: "calls/{uid}" + tail, status: r.status, content_type: ct.slice(0, 60), location: r.headers.get("location") ? mask(r.headers.get("location")!) : "", shape: j ? deep((j as Record<string, unknown>).data ?? j) : {},
          message: !r.ok && j ? String((j as Record<string, unknown>).message ?? "").slice(0, 160) : "" }); }
    } catch (e) { out.push({ path: "calls (closer look)", status: 0, message: String(e).slice(0, 160) }); }
    await admin.rpc("_podium_probe_save", { p: out });
    return json({ ok: true, results: out.map(o => ({ path: o.path, status: o.status })) });
  }

  if (body.action === "test") {
    if (!sec.refresh_token) return json({ need_connect: true });
    let access = sec.access_token && sec.expires && new Date(sec.expires).getTime() > Date.now() ? sec.access_token : null;
    const renew = async () => { const t = await tokens({ grant_type: "refresh_token", refresh_token: sec.refresh_token! });
      if ("error" in t) return t.error;
      await admin.rpc("_podium_save", { p_access: t.access, p_refresh: t.refresh, p_expires: t.expires, p_user: null, p_locations: null, p_error: null }); access = t.access; return null; };
    if (!access) { const e = await renew(); if (e) { await admin.rpc("_podium_save", { p_access: null, p_refresh: null, p_expires: null, p_user: null, p_locations: null, p_error: e }); return json({ error: "podium", message: e }); } }
    let loc = await locations(access!);
    if (loc.status === 401) { const e = await renew(); if (!e) loc = await locations(access!); }
    await admin.rpc("_podium_save", { p_access: null, p_refresh: null, p_expires: null, p_user: null, p_locations: loc.list ?? null, p_error: loc.error ?? null });
    if (loc.error) return json({ error: "podium", message: loc.error });
    return json({ ok: true, locations: loc.list });
  }
  return json({ error: "bad_request" }, 400);
});

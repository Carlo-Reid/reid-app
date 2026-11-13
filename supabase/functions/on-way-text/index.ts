// Supabase Edge Function: on-way-text   (keep "Verify JWT" ON: only signed-in staff use it)
// Tech Calls, "On my way": one text to the customer through Podium with the tech's first name, about how many minutes, and his picture.
//   { visit_id, lat, lng, card }  → (card: the picture the app drew, a JPEG as base64: the tech's picture with the side bar; without it the plain Staff page picture goes)
//   { sent, minutes, pic, tech, test_to } | { already } | { error }
// Who may, which number, the minutes and the picture come from the database (on_way_text_info, sync/extra/286_on_my_way_text.sql).
// Once for each call. Test mode (Settings: Sending to customers) sends it to the test number instead of the customer.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const API = "https://api.podium.com";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });
const timed = async (url: string, ms: number, init: RequestInit = {}) => { const c = new AbortController(); const t = setTimeout(() => c.abort(), ms); try { return await fetch(url, { ...init, signal: c.signal }); } finally { clearTimeout(t); } };
type Sec = { client_id?: string; client_secret?: string; refresh_token?: string; access_token?: string; expires?: string | null };
type Way = { error?: string; already?: boolean; user?: number; phone?: string; tech?: string; minutes?: number; km?: number; company?: string; test_to?: string; image?: string; mime?: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "post_only" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!, auth = req.headers.get("Authorization") ?? "";
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  let body: { visit_id?: number; lat?: number | null; lng?: number | null; card?: string | null } = {};
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400);  }
  const visit = Number(body.visit_id) || 0, num = (v: unknown) => v != null && Number.isFinite(Number(v)) ? Number(v) : null;
  if (!visit) return json({ error: "bad_request" }, 400);
  const way = (await asUser.rpc("on_way_text_info", { p_visit: visit, p_lat: num(body.lat), p_lng: num(body.lng) })).data as Way | null;
  if (!way || way.error) return json({ error: way?.error ?? "not_allowed" });
  if (way.already) return json({ already: true });
  const d = String(way.phone ?? "").replace(/\D/g, "").slice(-10); if (d.length !== 10) return json({ error: "no_phone" });
  let to = d, testTo: string | null = null;
  if (way.test_to) { if (way.test_to === "none") return json({ error: "test_no_number" }); testTo = way.test_to; to = testTo; }

  const sec = ((await admin.rpc("_podium_secrets")).data ?? {}) as Sec;
  if (!sec.client_id || !sec.client_secret || !sec.refresh_token) return json({ error: "not_connected" });
  let token = sec.access_token && sec.expires && new Date(sec.expires).getTime() > Date.now() ? sec.access_token : null;
  if (!token) {
    try {
      const r = await timed(API + "/oauth/token", 20000, { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ client_id: sec.client_id, client_secret: sec.client_secret, grant_type: "refresh_token", refresh_token: sec.refresh_token }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok || !j.access_token) return json({ error: "podium", message: String(j.error_description ?? j.error ?? j.message ?? ("Podium said no (" + r.status + ")")).slice(0, 200) });
      const secs = Number(j.expires_in) > 0 ? Number(j.expires_in) : 36000; token = String(j.access_token);
      await admin.rpc("_podium_save", { p_access: token, p_refresh: j.refresh_token ? String(j.refresh_token) : null, p_expires: new Date(Date.now() + (secs - 300) * 1000).toISOString(), p_user: null, p_locations: null, p_error: null });
    } catch { return json({ error: "podium", message: "Podium did not answer." }); }
  }
  const loc = (((await admin.from("podium_conn").select("locations").eq("id", 1).maybeSingle()).data?.locations ?? []) as { uid?: string }[])[0]?.uid ?? null;
  if (!loc) return json({ error: "no_location" });

  const mins = Number(way.minutes) > 0 ? Number(way.minutes) : null, pre = testTo ? "[TEST: this would go to " + d.replace(/(\d{3})(\d{3})(\d{4})/, "$1-$2-$3") + "] " : "";
  const words = "Hi, this is " + (way.company || "the office") + ". " + (way.tech ? "Your technician " + way.tech : "Your technician") + " is on the way" + (mins ? " and should be there in about " + mins + " minutes" : "") + ".";
  const card = typeof body.card === "string" && body.card.startsWith("/9j/") && body.card.length < 900000 && /^[A-Za-z0-9+/=]+$/.test(body.card) ? body.card : null;
  const pict = card ?? way.image ?? null, pictMime = card ? "image/jpeg" : (way.mime || "image/jpeg");
  const picWords = !pict ? "" : " This is " + (way.tech || "your technician") + "'s picture, so you know who is coming.";
  const msg = (text: string) => ({ channel: { type: "phone", identifier: "+1" + to }, body: text, locationUid: loc, ...(way.tech ? { senderName: way.tech } : {}) });
  let ok = false, pic = false, sent = pre + words, why = "", j: Record<string, unknown> = {};
  if (pict) {   // with his picture: Podium's "message with attachment" (a form with the file and the message). Two ways to write the message part, in case Podium wants one of them.
    try {
      const bin = Uint8Array.from(atob(pict), c => c.charCodeAt(0)), mime = pictMime, ext = mime.includes("png") ? "png" : mime.includes("webp") ? "webp" : "jpg";
      for (const asJson of [false, true]) {
        const f = new FormData(), data = JSON.stringify(msg(pre + words + picWords));
        f.append("attachment", new Blob([bin], { type: mime }), "technician." + ext);
        if (asJson) f.append("data", new Blob([data], { type: "application/json" })); else f.append("data", data);
        const r = await timed(API + "/v4/messages/attachment", 25000, { method: "POST", headers: { Authorization: "Bearer " + token, Accept: "application/json" }, body: f });
        j = await r.json().catch(() => ({}));
        if (r.ok) { ok = true; pic = true; sent = pre + words + picWords; break; }
        why = String(j.message ?? j.error ?? ("Podium said no (" + r.status + ")")).slice(0, 200);
      }
    } catch { why = why || "Podium did not take the picture."; }
  }
  if (!ok) {   // no picture on file, or Podium would not take it: the words alone
    try {
      const r = await timed(API + "/v4/messages", 20000, { method: "POST", headers: { Authorization: "Bearer " + token, "Content-Type": "application/json", Accept: "application/json" }, body: JSON.stringify(msg(sent)) });
      j = await r.json().catch(() => ({}));
      if (!r.ok) return json({ error: "podium", message: String(j.message ?? j.error ?? ("Podium said no (" + r.status + ")")).slice(0, 300) });
    } catch { return json({ error: "podium", message: "Podium did not answer." }); }
  }
  const m = (j.data && typeof j.data === "object" ? j.data : j) as Record<string, unknown>;
  await admin.rpc("_podium_msg_in", { p_dir: "out", p_status: "sent", p: { uid: m.uid ?? null, body: sent, phone: d, createdAt: new Date().toISOString() }, p_sent_by: way.user ?? null, p_test_to: testTo });
  await admin.rpc("_on_way_text_sent", { p_visit: visit, p_user: way.user ?? null, p: { minutes: mins, km: way.km ?? null, phone: d, tech: way.tech ?? null, pic, test_to: testTo } });
  return json({ sent: true, test_to: testTo, minutes: mins, pic, tech: way.tech ?? null, pic_why: pict && !pic ? why : null });
});

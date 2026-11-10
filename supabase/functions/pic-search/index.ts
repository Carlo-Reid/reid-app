// Supabase Edge Function: pic-search   (keep "Verify JWT" ON: only signed-in staff use it)
// Pictures from the web for a new price list item (Auto update → Yes, add it → Picture → Pick one from the web).
//   { action: "search", q }   → looks the words up on SerpApi's Google Images and returns up to 30 pictures (small picture + full picture address)
//   { action: "fetch", url }  → brings one picture back as base64, because the browser is not allowed to read pictures from other websites itself
// Only people who can change the price list may use it (pic_search_allowed). The SerpApi key lives in the database vault (serpapi_key);
// an owner pastes it once in the app. It is never sent to the browser. See sync/extra/239_pic_search.sql.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });
const timed = async (url: string, ms: number, init: RequestInit = {}) => { const c = new AbortController(); const t = setTimeout(() => c.abort(), ms); try { return await fetch(url, { ...init, signal: c.signal }); } finally { clearTimeout(t); } };
// never fetch this server's own network: https only, a real website name, no bare addresses
const safeUrl = (s: string) => { try { const u = new URL(s); const h = u.hostname.toLowerCase();
    if (u.protocol !== "https:" || u.username || u.password) return null;
    if (!h.includes(".") || /^[\d.]+$/.test(h) || h.includes(":") || h === "localhost" || /\.(local|internal|localhost|lan|home|corp)$/.test(h)) return null;
    return u; } catch { return null; } };
const b64 = (buf: Uint8Array) => { let s = ""; for (let i = 0; i < buf.length; i += 0x8000) s += String.fromCharCode(...buf.subarray(i, i + 0x8000)); return btoa(s); };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "post_only" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!, auth = req.headers.get("Authorization") ?? "";
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const who = await asUser.rpc("pic_search_allowed");
  if (who.error || !who.data) return json({ error: "not_allowed" });
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  let body: { action?: string; q?: string; url?: string } = {};
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }

  if (body.action === "search") {
    const q = String(body.q ?? "").replace(/\s+/g, " ").trim().slice(0, 120);
    if (q.length < 2) return json({ error: "no_words" });
    const key = (await admin.rpc("_pic_search_key")).data as string | null;
    if (!key) return json({ need_key: true });
    let j: Record<string, unknown>;
    try { const r = await timed("https://serpapi.com/search.json?engine=google_images&hl=en&gl=ca&safe=active&q=" + encodeURIComponent(q) + "&api_key=" + encodeURIComponent(key), 25000);
      j = await r.json(); } catch { return json({ error: "search_failed", message: "The picture search did not answer." }); }
    if (j.error) return json({ error: /invalid api key/i.test(String(j.error)) ? "bad_key" : /run out|limit|exceed|plan/i.test(String(j.error)) ? "used_up" : "search_failed", message: String(j.error).slice(0, 200) });
    const list = (Array.isArray(j.images_results) ? j.images_results : []) as Record<string, unknown>[];
    const images = list.filter(x => typeof x.thumbnail === "string" && typeof x.original === "string").slice(0, 30)
      .map(x => ({ thumb: x.thumbnail, original: x.original, title: String(x.title ?? "").slice(0, 120), source: String(x.source ?? "").slice(0, 60), w: x.original_width ?? null, h: x.original_height ?? null }));
    await admin.rpc("_pic_search_log", { p_user: who.data, p_q: q, p_n: images.length });
    return json({ images });
  }

  if (body.action === "fetch") {
    const u = safeUrl(String(body.url ?? ""));
    if (!u) return json({ error: "bad_address" });
    try {
      const r = await timed(u.href, 15000, { redirect: "follow", headers: { "User-Agent": "Mozilla/5.0 (compatible; reid-app picture picker)", "Accept": "image/*" } });
      if (!r.ok || !safeUrl(r.url)) return json({ error: "no_picture" });
      const type = (r.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
      if (!/^image\/(jpeg|png|webp|gif|avif|bmp)$/.test(type)) return json({ error: "not_a_picture" });
      const buf = new Uint8Array(await r.arrayBuffer());
      if (buf.length < 200 || buf.length > 8 * 1024 * 1024) return json({ error: "too_big" });
      return json({ type, b64: b64(buf) });
    } catch { return json({ error: "no_picture" }); }
  }
  return json({ error: "bad_request" }, 400);
});

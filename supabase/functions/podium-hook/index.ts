// Supabase Edge Function: podium-hook   ("Verify JWT" OFF: Podium calls this, not a signed-in person. It checks Podium's signature itself.)
// Podium sends every call and text here the moment it happens (the webhook made by the podium function, action "live_on").
// Each message is signed: HMAC-SHA256 of "<podium-timestamp>.<raw body>" with our shared secret (vault: podium_webhook_secret), in the
// podium-signature header. Anything not signed right is refused and nothing is saved. See sync/extra/248_podium_live.sql.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const reply = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
const same = (a: string, b: string) => { if (a.length !== b.length) return false; let x = 0; for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i); return x === 0; };

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "post_only" }, 405);
  const raw = await req.text();
  if (raw.length > 1_000_000) return reply({ error: "too_big" }, 413);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const ts = req.headers.get("podium-timestamp") ?? "", sig = (req.headers.get("podium-signature") ?? "").trim().replace(/^sha256=/i, "");
  const secret = (await admin.rpc("_podium_hook_secret")).data as string | null;
  let ok = false;
  if (secret && ts && sig) {
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(ts + "." + raw)));
    const hex = [...mac].map(b => b.toString(16).padStart(2, "0")).join(""), b64 = btoa(String.fromCharCode(...mac));
    ok = same(sig.toLowerCase(), hex) || same(sig, b64) || same(sig, b64.replace(/=+$/, "")) || same(sig, b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""));
  }
  if (!ok) { await admin.rpc("_podium_hook_note", { p: { ok: false, reason: !secret ? "no secret" : !ts || !sig ? "no signature" : "bad signature", sig_len: sig.length, has_ts: !!ts } }); return reply({ error: "not_signed" }, 401); }
  let j: Record<string, unknown>; try { j = JSON.parse(raw); } catch { return reply({ error: "bad_json" }, 400); }
  const meta = (j.metadata ?? {}) as Record<string, unknown>;
  const type = String(meta.eventType ?? meta.event_type ?? j.eventType ?? j.event_type ?? "").toLowerCase();
  const data = (j.data && typeof j.data === "object" ? j.data : j) as Record<string, unknown>;
  let err: string | null = null;
  if (type.startsWith("call.")) err = (await admin.rpc("_podium_call_in", { p_event: type, p: data })).error?.message ?? null;
  else if (type === "message.received") err = (await admin.rpc("_podium_msg_in", { p_dir: "in", p_status: "received", p: data })).error?.message ?? null;
  else if (type === "message.sent") err = (await admin.rpc("_podium_msg_in", { p_dir: "out", p_status: "sent", p: data })).error?.message ?? null;
  else if (type === "message.failed") err = (await admin.rpc("_podium_msg_in", { p_dir: "out", p_status: "failed", p: data })).error?.message ?? null;
  await admin.rpc("_podium_hook_note", { p: { ok: !err, event: type || "(none)", keys: Object.keys(data).slice(0, 30), top: Object.keys(j).slice(0, 10), ...(err ? { error: err.slice(0, 200) } : {}) } });
  return reply({ ok: true });
});

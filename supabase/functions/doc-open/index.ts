// Supabase Edge Function: doc-open   (turn OFF "Verify JWT" for this one: customers click it without signing in)
// The links in anything sent with send-doc come here with the send's secret code (?t=…):
//   &k=open           the tiny picture in an email: notes that it was opened, returns a 1×1 picture
//   &k=view / &k=pdf  the links in the email or text: shows a page first asking "Do you want to view this proposal?"
//                     and who they are (it was sent to me / it was forwarded to me + name, who sent it). Every time.
//   &k=see            they said yes: notes who it was, shows the PDF (k=pdf links download it)
//   &k=no             they said no thanks
// Each visit is written down with the device and the rough place (city / region from the network), so the app
// can show opens and spot forwards. It only ever shows the one document that matches the secret code.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const PIXEL = Uint8Array.from(atob("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"), c => c.charCodeAt(0));
const esc = (s: string) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const PHONE = "(613) 233-1115";
const shell = (inner: string, status = 200) => new Response(
  `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
   <title>Reid Heating &amp; Cooling</title>
   <style>
     body{margin:0;font-family:Arial,Helvetica,sans-serif;background:#eef2f6;color:#1c2630}
     .card{max-width:460px;margin:40px auto;background:#fff;border-radius:14px;box-shadow:0 6px 24px rgba(0,0,0,.08);padding:26px 24px}
     h1{font-size:20px;margin:0 0 4px} .co{color:#5b6b78;font-size:13px;margin-bottom:18px}
     .q{font-size:16px;font-weight:bold;margin:18px 0 10px}
     label.opt{display:flex;gap:10px;align-items:flex-start;border:1px solid #d5dde3;border-radius:10px;padding:12px;margin:8px 0;cursor:pointer;font-size:15px}
     label.opt input{margin-top:2px;transform:scale(1.2)}
     .more{display:none;margin:8px 0 0 30px} .more input{width:100%;box-sizing:border-box;padding:10px;font-size:15px;border:1px solid #c9d2da;border-radius:8px;margin:4px 0 8px}
     .go{display:block;width:100%;margin-top:18px;background:#1f6fd1;color:#fff;border:0;border-radius:10px;padding:14px;font-size:16px;font-weight:bold;cursor:pointer}
     .no{display:block;text-align:center;margin-top:12px;color:#5b6b78;font-size:14px}
     .small{color:#8a99a6;font-size:12px;margin-top:18px;line-height:1.4}
   </style>
   <body><div class="card">${inner}</div></body></html>`,
  { status, headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "private, no-store" } });
const msgPage = (msg: string, status = 200) => shell(`<h1>Reid Heating &amp; Cooling</h1><p style="font-size:15px;line-height:1.5">${msg}</p>`, status);

// the rough place a visit came from (city / region / country, and the internet company), from the network address
async function geo(ip: string) {
  if (!ip || /^(10\.|127\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(ip)) return null;
  try {
    const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 1500);
    const r = await fetch(`https://ipapi.co/${encodeURIComponent(ip)}/json/`, { signal: ctl.signal, headers: { "User-Agent": "reid-doc-open" } });
    clearTimeout(t);
    if (!r.ok) return null;
    const j = await r.json();
    if (j.error) return null;
    return { city: j.city || "", region: j.region || "", country: j.country_name || "", org: j.org || "" };
  } catch { return null; }
}

Deno.serve(async (req) => {
  const u = new URL(req.url), t = u.searchParams.get("t") ?? "", kq = u.searchParams.get("k") ?? "open";
  const ok = /^[0-9a-f-]{36}$/i.test(t);
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || req.headers.get("x-real-ip") || "";
  const ua = req.headers.get("user-agent") ?? "";
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const base = { lang: req.headers.get("accept-language") ?? "", referer: req.headers.get("referer") ?? "" };

  // the picture in an email
  if (kq !== "view" && kq !== "pdf" && kq !== "see" && kq !== "no") {
    if (ok) await db.rpc("doc_send_hit", { p_token: t, p_kind: "open", p_ip: ip, p_ua: ua, p_info: base });
    return new Response(PIXEL, { headers: { "Content-Type": "image/gif", "Cache-Control": "no-store, no-cache, must-revalidate, private" } });
  }
  if (!ok) return msgPage(`This link isn't complete. Please call us at ${PHONE} and we'll send it again.`, 404);
  const where = await geo(ip);

  // they said no thanks
  if (kq === "no") {
    await db.rpc("doc_send_hit", { p_token: t, p_kind: "no", p_ip: ip, p_ua: ua, p_info: { ...base, geo: where } });
    return msgPage(`No problem. If you change your mind, the link in your message still works, or call us at ${PHONE}.`);
  }

  // they said yes: note who they are, then show (or download) the PDF
  if (kq === "see") {
    const who = u.searchParams.get("who") === "forwarded" ? "forwarded" : "me";
    const name = (u.searchParams.get("name") ?? "").slice(0, 120), from = (u.searchParams.get("from") ?? "").slice(0, 120);
    const dl = u.searchParams.get("dl") === "1";
    const r = await db.rpc("doc_send_hit", { p_token: t, p_kind: dl ? "pdf" : "view", p_ip: ip, p_ua: ua, p_info: { ...base, geo: where, who, name, from } });
    const d = r.data as { kind?: string; file_name?: string; pdf?: string } | null;
    const what = d?.kind === "invoice" ? "invoice" : d?.kind === "estimate" ? "proposal" : "document";
    if (!d) return msgPage(`This link isn't valid any more. Please call us at ${PHONE} and we'll send it again.`, 404);
    if (!d.pdf) return msgPage(`Thank you. Please call us at ${PHONE} if you'd like another copy of your ${what}.`);
    const bytes = Uint8Array.from(atob(d.pdf), c => c.charCodeAt(0));
    return new Response(bytes, { headers: { "Content-Type": "application/pdf",
      "Content-Disposition": `${dl ? "attachment" : "inline"}; filename="${(d.file_name || what + ".pdf").replace(/"/g, "")}"`, "Cache-Control": "private, no-store" } });
  }

  // the first page, every time: do you want to view it, and who are you?
  const r = await db.rpc("doc_send_hit", { p_token: t, p_kind: "ask", p_ip: ip, p_ua: ua, p_info: { ...base, geo: where } });
  const d = r.data as { kind?: string; title?: string; sent_on?: string } | null;
  if (!d) return msgPage(`This link isn't valid any more. Please call us at ${PHONE} and we'll send it again.`, 404);
  const what = d.kind === "invoice" ? "invoice" : d.kind === "estimate" ? "proposal" : "document";
  const me = new URL(req.url); me.search = "";
  const action = me.toString();
  return shell(`
    <h1>${esc(d.title || "Your " + what)}</h1>
    <div class="co">From Reid Heating &amp; Cooling${d.sent_on ? " · sent " + esc(d.sent_on) : ""}</div>
    <form method="get" action="${esc(action)}">
      <input type="hidden" name="t" value="${esc(t)}"><input type="hidden" name="k" value="see">${kq === "pdf" ? `<input type="hidden" name="dl" value="1">` : ""}
      <div class="q">Do you want to view this ${what}?</div>
      <label class="opt"><input type="radio" name="who" value="me" checked onchange="m.style.display='none'"> <span>Yes, it was sent to me</span></label>
      <label class="opt"><input type="radio" name="who" value="forwarded" onchange="m.style.display='block'"> <span>Yes, someone forwarded it to me</span></label>
      <div class="more" id="m">
        Your name<input name="name" maxlength="120" autocomplete="name">
        Who sent it to you?<input name="from" maxlength="120">
      </div>
      <button class="go" type="submit">View the ${what}</button>
      <a class="no" href="${esc(action)}?t=${esc(t)}&k=no">No thanks</a>
    </form>
    <div class="small">Questions? Call us at ${PHONE}. This link was made for you: please don't share it.</div>`);
});

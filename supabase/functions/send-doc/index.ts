// Supabase Edge Function: send-doc   (keep "Verify JWT" ON: only signed-in staff use it)
// Sends anything to a customer (an estimate, an invoice, any other document) by email or by text:
//   email: the message, a "View your estimate" button, the PDF attached when wanted, and a tiny picture so the app knows when it's opened
//   text:  the message and a link to view it (and a second link to the PDF when wanted), through Twilio
// While testing (company_settings.send_test_to is set), emails go to that address and texts to the sender's own cell.
// Secrets it uses (already there for invoices and staff texts): SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, optional SMTP_FROM_NAME / SMTP_BCC,
// TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM, optional PUBLIC_FUNCTIONS_URL.
import nodemailer from "npm:nodemailer@6.9.16";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply(405, { error: "Use POST" });

  // act as the person signed in, so the database checks their permission
  const auth = req.headers.get("Authorization") ?? "";
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } }, auth: { persistSession: false },
  });

  let input: { kind?: string; ref_id?: number | null; customer_id?: number | null; title?: string; label?: string; channel?: string; to?: string;
               subject?: string; body?: string; with_pdf?: boolean; pdf_b64?: string; file_name?: string };
  try { input = await req.json(); } catch { return reply(400, { error: "Bad request" }); }
  const channel = input.channel === "text" ? "text" : "email";
  const subject = String(input.subject ?? "").trim(), body = String(input.body ?? "");
  const label = String(input.label ?? input.kind ?? "document").trim() || "document";   // "estimate", "invoice"…
  if (!body.trim()) return reply(400, { error: "The message is empty" });
  if (channel === "email" && !subject) return reply(400, { error: "The subject is empty" });
  if ((input.pdf_b64 ?? "").length > 14_000_000) return reply(400, { error: "The PDF is too big to send" });

  if (channel === "email" && (!Deno.env.get("SMTP_USER") || !Deno.env.get("SMTP_PASS") || !Deno.env.get("SMTP_HOST")))
    return reply(500, { error: "Email isn't connected yet (the mailbox settings are missing in Supabase)" });
  const sid = Deno.env.get("TWILIO_ACCOUNT_SID"), tok = Deno.env.get("TWILIO_AUTH_TOKEN"), from = Deno.env.get("TWILIO_FROM");
  if (channel === "text" && (!sid || !tok || !from)) return reply(500, { error: "Texts aren't set up yet (the Twilio secrets are missing in Supabase)" });

  const start = await db.rpc("doc_send_start", {
    p_kind: input.kind ?? "other", p_ref: input.ref_id ?? null, p_customer: input.customer_id ?? null, p_title: input.title ?? null,
    p_channel: channel, p_to: input.to ?? "", p_subject: subject, p_body: body,
    p_with_pdf: !!input.with_pdf, p_pdf_b64: input.pdf_b64 ?? "", p_file_name: input.file_name ?? "document.pdf",
  });
  if (start.error) return reply(400, { error: start.error.message });
  const s = start.data as { id: number; token: string; send_to: string; test: boolean };

  const base = (Deno.env.get("PUBLIC_FUNCTIONS_URL") ?? Deno.env.get("SUPABASE_URL") + "/functions/v1") + "/doc-open?t=" + s.token;
  let ok = true, error: string | null = null;

  if (channel === "email") {
    const testNote = s.test ? `TEST: while testing this was sent to you instead of ${input.to}.\n\n` : "";
    const text = testNote + body + `\n\nView your ${label} online: ${base}&k=view\n` + (input.with_pdf ? `(The ${label} is also attached as a PDF.)\n` : "");
    const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#222;line-height:1.5">
      ${s.test ? `<p style="background:#fff3bf;padding:8px 10px;border-radius:6px"><b>TEST:</b> while testing this was sent to you instead of ${esc(String(input.to))}.</p>` : ""}
      <div style="white-space:pre-wrap;margin:0 0 18px">${esc(body)}</div>
      <p><a href="${base}&k=view" style="display:inline-block;background:#1f6fd1;color:#fff;text-decoration:none;padding:11px 20px;border-radius:6px;font-weight:bold">View your ${esc(label)}</a></p>
      ${input.with_pdf ? `<p style="color:#666;font-size:12px">The ${esc(label)} is also attached as a PDF.</p>` : ""}
      <img src="${base}&k=open" width="1" height="1" alt="" style="display:block;border:0;width:1px;height:1px"></div>`;
    const port = Number(Deno.env.get("SMTP_PORT") ?? "465");
    const transporter = nodemailer.createTransport({
      host: Deno.env.get("SMTP_HOST"), port,
      secure: (Deno.env.get("SMTP_SECURE") ?? (port === 465 ? "true" : "false")) === "true",
      auth: { user: Deno.env.get("SMTP_USER"), pass: Deno.env.get("SMTP_PASS") },
    });
    try {
      await transporter.sendMail({
        from: { name: Deno.env.get("SMTP_FROM_NAME") ?? "Reid Heating & Cooling", address: Deno.env.get("SMTP_USER")! },
        to: s.send_to,
        bcc: s.test ? undefined : (Deno.env.get("SMTP_BCC") || undefined),
        subject: (s.test ? "[TEST] " : "") + subject,
        text, html,
        attachments: input.with_pdf && input.pdf_b64 ? [{ filename: input.file_name || "document.pdf", content: input.pdf_b64, encoding: "base64", contentType: "application/pdf" }] : [],
      });
    } catch (e) { ok = false; error = String((e as Error)?.message ?? e).slice(0, 400); }
  } else {
    const msg = (s.test ? `[TEST for ${input.to}] ` : "") + body.trim() + `\n\nView your ${label}: ${base}&k=view` + (input.with_pdf ? `\nPDF: ${base}&k=pdf` : "");
    try {
      const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
        method: "POST", headers: { Authorization: "Basic " + btoa(`${sid}:${tok}`), "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ To: "+1" + s.send_to, From: from!, Body: msg }) });
      if (!r.ok) { const j = await r.json().catch(() => ({})); ok = false; error = String(j.message || ("Twilio " + r.status)).slice(0, 400); }
    } catch (e) { ok = false; error = String((e as Error)?.message ?? e).slice(0, 400); }
  }

  await db.rpc("doc_send_done", { p_id: s.id, p_ok: ok, p_error: error });
  if (!ok) return reply(502, { error: (channel === "email" ? "The email wasn't sent: " : "The text wasn't sent: ") + error });
  return reply(200, { ok: true, id: s.id, sent_to: s.send_to, test: s.test });
});

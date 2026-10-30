// Supabase Edge Function: login-as   (keep "Verify JWT" ON)
// Lets Carlo (owner) sign in as another staff member from the Staff page, to see and test exactly what they see.
// Only the emails in ALLOWED can use it, and only while they are an active owner in the app. Nothing is emailed:
// it hands back a one-time sign-in code the app uses straight away. Every use is written to the audit log.
// It needs no new secrets: it uses the keys Supabase gives every Edge Function (the service role key, or the newer secret key).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const ALLOWED = ["carlo@homeservicegroup.ca"];

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply(405, { error: "Use POST" });
  const url = Deno.env.get("SUPABASE_URL")!, anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  // the admin key: the classic service role key, or (newer projects) the secret key
  let service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!service || service.startsWith("sb_publishable")) {
    try { const k = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}"); service = k.default ?? Object.values(k)[0] ?? service; } catch { /* keep */ }
    service = service || Deno.env.get("SUPABASE_SECRET_KEY") || "";
  }

  // who is asking
  const caller = createClient(url, anon, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } }, auth: { persistSession: false } });
  const { data: who } = await caller.auth.getUser();
  const myEmail = (who?.user?.email ?? "").toLowerCase();
  if (!myEmail || !ALLOWED.includes(myEmail)) return reply(403, { error: "Only Carlo can do this" });

  // checked as Carlo himself, so the database's own rules decide (no admin key needed for this part)
  const { data: myRole } = await caller.rpc("current_staff_role");
  if (myRole !== "owner") return reply(403, { error: "Only an active owner can do this" });
  const { data: me } = await caller.from("app_users").select("id").ilike("login_email", myEmail).limit(1).maybeSingle();
  if (!service) return reply(500, { error: "The function can't find the server's admin key (SUPABASE_SERVICE_ROLE_KEY)" });
  const admin = createClient(url, service, { auth: { persistSession: false } });

  let input: { app_user_id?: number };
  try { input = await req.json(); } catch { return reply(400, { error: "Bad request" }); }
  const { data: them } = await caller.from("app_users").select("id, login_email, active, deleted_at").eq("id", Number(input.app_user_id)).maybeSingle();
  if (!them || them.deleted_at) return reply(404, { error: "That person isn't in the app" });
  const email = String(them.login_email ?? "").toLowerCase();
  if (!email) return reply(400, { error: "They have no login email" });
  if (email === myEmail) return reply(400, { error: "That's you" });

  // a one-time sign-in code for them (nothing is sent to them)
  const { data: link, error } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  if (error || !link?.properties?.hashed_token) return reply(400, { error: /not found|no user/i.test(error?.message ?? "") ? "They don't have a login yet (use Create login first)"
    : /invalid api key|jwt|not allowed|unauthorized|forbidden/i.test(error?.message ?? "") ? "The function's admin key isn't working (" + (error?.message ?? "") + ")" : (error?.message ?? "Couldn't sign in as them") });

  await admin.from("audit_log").insert({ table_name: "app_users", row_id: them.id, action: "update", changed_by_user_id: me?.id ?? null,
    new_values: { signed_in_as_them_by: myEmail, at: new Date().toISOString() } }).then(() => {}, () => {});
  return reply(200, { token_hash: link.properties.hashed_token, email });
});

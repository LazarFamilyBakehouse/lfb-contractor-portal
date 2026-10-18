// LFB Contractor Portal - Notification emails
// Called from the portal (supabase.functions.invoke) with the signed-in
// user's JWT. Sends through Resend from the same sender as the partner
// portal. Recipients are validated server-side: a contractor can only
// trigger emails to themselves or to the LFB team; admins can email any
// active contractor. Contractor-facing one-off emails are BCC'd to the team.
import { createClient } from "npm:@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const FROM_EMAIL = Deno.env.get("DIGEST_FROM") ?? "orders@lazarfamilybakehouse.com";
const TEAM = ["info@lazarfamilybakehouse.com", "victoria@lazarfamilybakehouse.com"];
const PORTAL = "https://contractors.lazarfamilybakehouse.com";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Which events go where.
//   team      -> to TEAM only
//   self      -> to the contractor (payload.to_email must be caller or admin-chosen contractor); bcc TEAM
//   broadcast -> to one contractor per call (portal loops); no bcc
const KIND: Record<string, "team" | "self" | "broadcast"> = {
  test: "self",
  welcome: "self",
  contract_sent: "self",
  contract_signed: "team",
  contract_declined: "team",
  signup_confirm: "self",
  hours_submitted: "team",
  hours_approved: "self",
  kitchen_hours_reminder: "team",
  clock_out_reminder: "self",
  availability_nudge: "self",
  shift_new: "broadcast",
  shift_released: "broadcast",
  shift_released_team: "team",
  shift_cancelled: "broadcast",
};

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));

function wrap(title: string, bodyHtml: string, cta?: { label: string; url: string }) {
  return `<div style="font-family:Georgia,serif;max-width:600px;margin:0 auto;background:#fdf6ee;padding:24px;border-radius:12px;color:#2d1b0e;">
  <div style="font-family:Arial,sans-serif;font-size:11px;letter-spacing:.2em;text-transform:uppercase;color:#fff;background:#e60000;display:inline-block;padding:4px 10px;border-radius:4px;margin-bottom:14px;">Contractor Portal</div>
  <h2 style="margin:0 0 10px;color:#2d1b0e;">${title}</h2>
  <div style="font-size:15px;line-height:1.55;">${bodyHtml}</div>
  ${cta ? `<p style="margin:20px 0 6px;"><a href="${cta.url}" style="background:#e60000;color:#fff;text-decoration:none;padding:11px 18px;border-radius:6px;font-family:Arial,sans-serif;font-weight:bold;display:inline-block;">${esc(cta.label)}</a></p>` : ""}
  <p style="color:#b0a08c;font-size:12px;margin-top:20px;">Lazar Family Bakehouse · <a href="${PORTAL}" style="color:#b0a08c;">Contractor Portal</a></p>
</div>`;
}

function build(event: string, p: Record<string, unknown>) {
  const url = String(p.portal_url || PORTAL);
  const name = esc(p.first_name || "there");
  switch (event) {
    case "test":
      return { subject: "Test email from the Contractor Portal", html: wrap("It works", `<p>Hi ${name}, this is a test message from the LFB Contractor Portal. Email notifications are live.</p>`, { label: "Open the portal", url }) };
    case "welcome":
      return { subject: "Your Lazar Family Bakehouse Contractor Portal login", html: wrap("Welcome to the Contractor Portal", `<p>Hi ${name}, here is how to sign in to the LFB Contractor Portal, where you'll see upcoming bakes, sign up for shifts, log hours and track your pay.</p><table style="border-collapse:collapse;margin:10px 0;"><tr><td style="padding:6px 14px 6px 0;color:#7a6a58;">Portal</td><td style="padding:6px 0;"><a href="${url}" style="color:#e60000;font-weight:bold;">LFB Contractor Portal</a></td></tr><tr><td style="padding:6px 14px 6px 0;color:#7a6a58;">Email</td><td style="padding:6px 0;"><strong>${esc(p.login_email)}</strong></td></tr><tr><td style="padding:6px 14px 6px 0;color:#7a6a58;">PIN</td><td style="padding:6px 0;"><strong style="font-size:18px;letter-spacing:.15em;">${esc(p.pin)}</strong></td></tr></table><p style="color:#7a6a58;font-size:14px;">Keep this email handy; the PIN is your password. If it ever stops working, reply here and we'll reset it.</p>`, { label: "Open the portal", url }) };
    case "contract_sent":
      return { subject: `Please review and sign: ${p.contract_title}`, html: wrap("Your agreement is ready to sign", `<p>Hi ${esc(p.contractor_name || p.first_name || "there")},</p><p>Lazar Family Bakehouse has sent you the <strong>${esc(p.contract_title)}</strong> to review and sign electronically. Sign in to the Contractor Portal, open <strong>Agreements</strong>, read through it, and sign when you're ready. You'll get a PDF copy right away.</p>`, { label: "Review & sign", url }) };
    case "contract_signed":
      return { subject: `✍️ ${p.contractor_name} signed the ${p.contract_title}`, html: wrap("Contract signed", `<p><strong>${esc(p.contractor_name)}</strong> just signed the <strong>${esc(p.contract_title)}</strong>. The signed PDF with the signature page and audit certificate is in the Contracts tab.</p>`, { label: "Open Contracts", url }) };
    case "contract_declined":
      return { subject: `⚠️ ${p.contractor_name} declined to sign`, html: wrap("Contract declined", `<p><strong>${esc(p.contractor_name)}</strong> declined the agreement.</p>${p.reason ? `<p>Reason given: <em>${esc(p.reason)}</em></p>` : "<p>No reason was given.</p>"}<p>You may want to reach out and, if needed, send a revised version from the Contracts tab.</p>`, { label: "Open Contracts", url }) };
    case "signup_confirm":
      return { subject: `You're on the schedule: ${p.bake_date}`, html: wrap("You're signed up", `<p>Hi ${name}, you're confirmed for the bake on <strong>${esc(p.bake_date)}</strong>, <strong>${esc(p.start_time)}</strong>, at ${esc(p.location)}.</p><p>Notes: ${esc(p.shift_notes)}</p><p>If plans change, release your spot in the portal as early as you can so someone else can take it.</p>`, { label: "View my shifts", url }) };
    case "hours_submitted":
      return { subject: `Hours submitted: ${p.contractor_name}, ${p.bake_date}`, html: wrap("Hours waiting for approval", `<p><strong>${esc(p.contractor_name)}</strong> submitted <strong>${esc(p.submitted_hours)} hours</strong> for ${esc(p.bake_date)}.</p><p>Notes: ${esc(p.submitted_notes)}</p>`, { label: "Review in Approvals", url }) };
    case "hours_approved":
      return { subject: `Hours approved for ${p.bake_date}`, html: wrap("Your hours were approved", `<p>Hi ${name}, your hours for <strong>${esc(p.bake_date)}</strong> were approved: <strong>${esc(p.approved_hours)} hrs × ${esc(p.pay_rate)} = ${esc(p.approved_amount)}</strong>.</p>${p.admin_notes_line ? `<p>${esc(p.admin_notes_line)}</p>` : ""}<p style="color:#7a6a58;font-size:14px;">Year to date: ${esc(p.ytd_hours)} hrs · paid ${esc(p.ytd_paid)} · pending ${esc(p.ytd_pending)}</p>`, { label: "View payments", url }) };
    case "kitchen_hours_reminder":
      return { subject: `Log the kitchen hours: ${p.bake_date}`, html: wrap("Kitchen hours to log", `<p>The bake on <strong>${esc(p.bake_date)}</strong> at ${esc(p.location)} is complete (${esc(p.workers)}), but no Kent Denver kitchen hours are logged for that day yet.</p><p>Open the <strong>Kitchen</strong> tab, click <em>Log kitchen hours</em>, and enter the hours the kitchen was in use so what we owe Kent stays current.</p>`, { label: "Open Kitchen tab", url }) };
    case "clock_out_reminder":
      return { subject: `Clock out? You're still clocked in since ${p.clock_in_time}`, html: wrap("Still on the clock", `<p>Hi ${name}, you clocked in at <strong>${esc(p.clock_in_time)}</strong> and your shift was scheduled to end at <strong>${esc(p.expected_end_time)}</strong>, but you're still clocked in.</p><p>If you're done, open the portal and tap <strong>Clock out</strong>. You can set the time you actually finished, so the extra minutes won't count against your hours. If you're still working, ignore this.</p>`, { label: "Clock out now", url }) };
    case "availability_nudge":
      return { subject: "Quick favor: update your availability", html: wrap("Help us plan the next bakes", `<p>Hi ${name}, your availability in the portal looks out of date. It takes a minute to mark the days you're free, and it's how we decide when to schedule bakes.</p>`, { label: "Update availability", url }) };
    case "shift_new":
      return { subject: `New bake on ${p.bake_date}: ${p.spots_total} spot${String(p.spots_total) === "1" ? "" : "s"} open`, html: wrap("A new bake is open", `<p>Hi ${name}, a new bake is open on <strong>${esc(p.bake_date)}</strong> at ${esc(p.location)}.</p>${String(p.start_time || "").includes(" / ") ? `<p style="margin-bottom:4px;">Pick the time that works for you:</p><ul style="margin-top:0;">${String(p.start_time).split(" / ").map((w) => `<li><strong>${esc(w)}</strong></li>`).join("")}</ul>` : `<p>Time: <strong>${esc(p.start_time)}</strong></p>`}<p>${esc(p.spots_total)} spot${String(p.spots_total) === "1" ? "" : "s"} total.</p><p>Notes: ${esc(p.shift_notes)}</p><p>Spots are first come, first served.</p>`, { label: "Claim a spot", url }) };
    case "shift_released":
      return { subject: `A spot opened up: ${p.bake_date}`, html: wrap("A spot just opened", `<p>Hi ${name}, someone released their spot for the bake on <strong>${esc(p.bake_date)}</strong>, <strong>${esc(p.start_time)}</strong>, at ${esc(p.location)}. If you're free, grab it in the portal.</p>`, { label: "Claim the spot", url }) };
    case "shift_released_team":
      return { subject: `${p.contractor_name} released their spot: ${p.bake_date}`, html: wrap("A contractor dropped a shift", `<p><strong>${esc(p.contractor_name)}</strong> released their spot for the bake on <strong>${esc(p.bake_date)}</strong> (${esc(p.start_time)}, ${esc(p.location)}). That's ${esc(p.days_out)} day${String(p.days_out) === "1" ? "" : "s"} out.</p><p>Everyone else on the team has been emailed that the spot is open. Check the Shifts tab to see whether someone picks it up.</p>`, { label: "Open Shifts", url }) };
    case "shift_cancelled":
      return { subject: `Cancelled: bake on ${p.bake_date}`, html: wrap("Bake cancelled", `<p>Hi ${name}, the bake on <strong>${esc(p.bake_date)}</strong> at ${esc(p.location)} has been cancelled.</p>${p.cancel_reason_line ? `<p>${esc(p.cancel_reason_line)}</p>` : ""}<p>Sorry for the change. Keep an eye on the schedule for the next one.</p>`, { label: "See the schedule", url }) };
    default:
      return null;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
  try {
    if (!RESEND_API_KEY) return json({ error: "RESEND_API_KEY not set" }, 500);
    const auth = req.headers.get("Authorization") || "";

    // Scheduled job (pg_cron): send due clock-out reminders. No user session; the
    // DB decides who is due, so the only possible effect is a legitimate reminder.
    const early = await req.clone().json().catch(() => ({}));
    if (early && early.event === "clock_out_reminder" && early.cron === true) {
      const svc = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
      const { data: due, error: dErr } = await svc.rpc("c_clock_out_reminders_due");
      if (dErr) return json({ error: dErr.message }, 500);
      const fmt = (ts: string) => new Date(ts).toLocaleTimeString("en-US", { timeZone: "America/Denver", hour: "numeric", minute: "2-digit" });
      let sent = 0;
      for (const d of (due || []) as Array<Record<string, string>>) {
        const msg = build("clock_out_reminder", { first_name: d.first_name, clock_in_time: fmt(d.clock_in), expected_end_time: fmt(d.expected_end), portal_url: PORTAL })!;
        const r = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { Authorization: "Bearer " + RESEND_API_KEY, "Content-Type": "application/json" },
          body: JSON.stringify({ from: "Lazar Family Bakehouse <" + FROM_EMAIL + ">", to: [d.email], reply_to: "info@lazarfamilybakehouse.com", subject: msg.subject, html: msg.html }),
        });
        if (r.ok) { sent++; await svc.from("c_time_entries").update({ reminder_count: Number(d.reminder_count || 0) + 1, last_reminder_at: new Date().toISOString() }).eq("id", d.entry_id); }
      }
      return json({ cron: true, due: (due || []).length, sent });
    }

    const sbUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: { user }, error: uErr } = await sbUser.auth.getUser();
    if (uErr || !user) return json({ error: "not signed in" }, 401);

    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: me } = await sb.from("c_contractors").select("id,email,role,status,first_name").eq("user_id", user.id).maybeSingle();
    if (!me || me.status !== "active") return json({ error: "no active contractor profile" }, 403);
    const isAdmin = me.role === "admin";

    const body = await req.json().catch(() => ({}));
    const event = String(body.event || "");
    const kind = KIND[event];
    if (!kind) return json({ error: "unknown event " + event }, 400);

    // Resolve recipients
    let to: string[] = [];
    let bcc: string[] = [];
    const want = String(body.to_email || "").toLowerCase().trim();
    if (kind === "team") {
      to = TEAM;
    } else {
      const { data: actives } = await sb.from("c_contractors").select("email").eq("status", "active");
      const allowed = new Set((actives || []).map((r: { email: string }) => String(r.email).toLowerCase()));
      if (!want) return json({ error: "to_email required" }, 400);
      if (event === "welcome" && !isAdmin) return json({ error: "admin only" }, 403);
      if (isAdmin) {
        if (!allowed.has(want) && !TEAM.includes(want)) return json({ error: "recipient is not an active contractor" }, 400);
      } else {
        const selfOk = want === String(me.email).toLowerCase();
        const broadcastOk = kind === "broadcast" && event === "shift_released" && allowed.has(want);
        if (!selfOk && !broadcastOk) return json({ error: "not allowed to email that recipient" }, 403);
      }
      to = [want];
      if (kind === "self" && event !== "test" && event !== "welcome") bcc = TEAM.filter((t) => t !== want);
    }

    const msg = build(event, body);
    if (!msg) return json({ error: "no template for " + event }, 400);

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: "Bearer " + RESEND_API_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ from: "Lazar Family Bakehouse <" + FROM_EMAIL + ">", to, ...(bcc.length ? { bcc } : {}), reply_to: "info@lazarfamilybakehouse.com", subject: msg.subject, html: msg.html }),
    });
    const out = await res.json().catch(() => ({}));
    if (!res.ok) return json({ error: "resend " + res.status, detail: out }, 502);
    return json({ sent: to.length, to, bcc, id: out.id });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});

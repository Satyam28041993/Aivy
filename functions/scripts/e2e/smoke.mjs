/**
 * End-to-end smoke test against the LIVE project, as the user would use it.
 *
 * Signs up a throwaway anonymous user (anonymous sign-in is enabled even
 * though the app signs those users out), then talks to the deployed
 * `aivyAgent` / `aivyAgentCommit` callables in Hinglish: a DSR visit with the
 * location question and a follow-up, a second visit, the day's travel
 * expense, a visiting card's front and back, delete and undo — and finally
 * reads Firestore back to check what was actually written.
 *
 * It hits live Gemini and Firestore, so it leaves real rows under that
 * throwaway uid. No Google token is sent, so the sheets take their
 * "catches up later" path — the server-side Sheets calls are covered by
 * unit tests, not here.
 *
 * Run by the "E2E smoke" workflow. Prints the whole conversation, then a
 * PASS/FAIL list; exits 1 if any check failed.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const API_KEY = "AIzaSyD9kg-3Q5Etl9GQ_EJqvw2MQvyogCDeCqw"; // public web key
const PROJECT = "aivy-5c031";
const BUCKET = "aivy-5c031.firebasestorage.app";
const FN = `https://us-central1-${PROJECT}.cloudfunctions.net`;
const TZ = "Asia/Kolkata";

const WALUJ = { lat: 19.8436, lng: 75.238 };
const CHIKALTHANA = { lat: 19.8698, lng: 75.3871 };

let token = "";
let uid = "";
let chatId = "";
const checks = [];

function check(name, ok, detail = "") {
  checks.push({ name, ok: Boolean(ok), detail });
  console.log(`${ok ? "  ✅" : "  ❌"} ${name}${detail ? ` — ${detail}` : ""}`);
}

async function post(url, body, headers = {}) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    return { error: res.status, body: text.slice(0, 500) };
  }
}

async function signUp() {
  const r = await post(`https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${API_KEY}`, {
    returnSecureToken: true,
  });
  token = r.idToken;
  uid = r.localId;
  console.log(`Signed in as throwaway uid ${uid}\n`);
}

/** One user message. Returns { reply, drafts }. */
async function say(text, opts = {}) {
  console.log(`\n🧑 SATYAM: ${text}${opts.at ? `   [phone at ${opts.at.lat},${opts.at.lng}]` : ""}${opts.attachments ? `   [📎 ${opts.attachments.map((a) => a.name).join(", ")}]` : ""}`);
  const data = { text, timezone: TZ, chatId, ...(opts.at ?? {}), ...(opts.attachments ? { attachments: opts.attachments } : {}) };
  const r = await post(`${FN}/aivyAgent`, { data }, { Authorization: `Bearer ${token}` });
  const res = r.result ?? r;
  if (res.error || !res.reply) {
    console.log("   ⚠️ ERROR:", JSON.stringify(res).slice(0, 600));
    return { reply: "", drafts: [], error: true };
  }
  if (res.chatId) chatId = res.chatId;
  console.log(`🤖 AIVY: ${res.reply}`);
  for (const d of res.drafts ?? []) {
    console.log(`   ┌ CARD [${d.kind}] ${d.title}  (id ${d.id})`);
    for (const l of d.lines ?? []) console.log(`   │ ${l.label}: ${l.value}`);
    console.log("   └");
  }
  return { reply: res.reply, drafts: res.drafts ?? [] };
}

async function confirm(draft) {
  const r = await post(
    `${FN}/aivyAgentCommit`,
    { data: { draftId: draft.id, chatId } },
    { Authorization: `Bearer ${token}` },
  );
  const res = r.result ?? r;
  console.log(`✔️  CONFIRMED [${draft.kind}] → ${res.message ?? JSON.stringify(res).slice(0, 400)}`);
  return res;
}

/** Keeps answering until a card of `kind` appears (the model may ask first). */
async function untilCard(kind, first, answers, opts = {}) {
  let turn = await say(first, opts);
  for (const a of answers) {
    const card = turn.drafts.find((d) => d.kind === kind);
    if (card) return { card, turn };
    turn = await say(a, opts);
  }
  return { card: turn.drafts.find((d) => d.kind === kind) ?? null, turn };
}

async function upload(file) {
  const bytes = readFileSync(join(here, file));
  const path = `users/${uid}/agent_files/${Date.now()}_${file}`;
  const res = await fetch(
    `https://firebasestorage.googleapis.com/v0/b/${BUCKET}/o?uploadType=media&name=${encodeURIComponent(path)}`,
    { method: "POST", headers: { Authorization: `Firebase ${token}`, "Content-Type": "image/png" }, body: bytes },
  );
  if (!res.ok) throw new Error(`upload ${file}: ${res.status} ${await res.text()}`);
  return { storagePath: path, mimeType: "image/png", name: file };
}

const FS = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;

function plain(v) {
  if (!v || typeof v !== "object") return v;
  if ("stringValue" in v) return v.stringValue;
  if ("integerValue" in v) return Number(v.integerValue);
  if ("doubleValue" in v) return v.doubleValue;
  if ("booleanValue" in v) return v.booleanValue;
  if ("nullValue" in v) return null;
  if ("arrayValue" in v) return (v.arrayValue.values ?? []).map(plain);
  if ("mapValue" in v) return Object.fromEntries(Object.entries(v.mapValue.fields ?? {}).map(([k, x]) => [k, plain(x)]));
  return v;
}

async function list(collection) {
  const res = await fetch(`${FS}/users/${uid}/${collection}?pageSize=100`, { headers: { Authorization: `Bearer ${token}` } });
  const j = await res.json();
  return (j.documents ?? []).map((d) => ({ id: d.name.split("/").pop(), ...plain({ mapValue: { fields: d.fields ?? {} } }) }));
}

async function myContacts() {
  const res = await fetch(`${FS}:runQuery`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      structuredQuery: {
        from: [{ collectionId: "contacts" }],
        where: { fieldFilter: { field: { fieldPath: "ownerUid" }, op: "EQUAL", value: { stringValue: uid } } },
      },
    }),
  });
  const j = await res.json();
  return (Array.isArray(j) ? j : [])
    .filter((r) => r.document)
    .map((r) => ({ id: r.document.name.split("/").pop(), ...plain({ mapValue: { fields: r.document.fields } }) }));
}

async function main() {
  await signUp();

  // --- 1. Visit with the location question and a follow-up ----------------
  console.log("\n════════ 1. Visit record (DSR) + location + follow-up ════════");
  const v1 = await untilCard(
    "visit",
    "visit record karo — Bajaj Auto gaya tha, Mr. Sharma purchase head se mila, BX410T printer aur wax resin ribbon pe baat hui, interested hai, quotation bhejna hai",
    ["haan main abhi Bajaj Auto pe hi hu, yahi location save karlo", "haan abhi client ki jagah pe hu, bas itna hi"],
    { at: WALUJ },
  );
  check("visit: asked before drawing the card or drew it with the details", v1.card);
  if (v1.card) {
    check("visit: card has the client", v1.card.lines.some((l) => /bajaj/i.test(l.value)));
    check("visit: location pin kept after 'yes, at client'", v1.card.lines.some((l) => l.label === "Pin"));
    const c = await confirm(v1.card);
    check("visit: confirm asks about a follow-up", /follow-up/i.test(c.message ?? ""));
    const f = await untilCard("visit_followup", "haan, 10 din baad follow up lagao", ["10 din baad, subah 11 baje"]);
    check("follow-up: card drawn", f.card);
    if (f.card) await confirm(f.card);
  }

  // --- 2. Second visit, not at the client ---------------------------------
  console.log("\n════════ 2. Second visit, NOT at client ════════");
  const v2 = await untilCard(
    "visit",
    "ek aur visit record karo: Exide Industries Chikalthana, Mr. Kulkarni stores incharge se mila, TTR ribbons ka demo diya, next week order dene bole",
    ["nahi, abhi client pe nahi hu, location Chikalthana MIDC Aurangabad likh do", "nahi, bas itna hi"],
    { at: CHIKALTHANA },
  );
  check("visit 2: card drawn", v2.card);
  if (v2.card) {
    check("visit 2: no pin when not at the client", !v2.card.lines.some((l) => l.label === "Pin"));
    await confirm(v2.card);
    await say("nahi follow up nahi chahiye");
  }

  // --- 3. Travel expense --------------------------------------------------
  console.log("\n════════ 3. Travel expense (km) ════════");
  const e = await untilCard(
    "travel_expense",
    "aaj ka expense entry karo, start point CIDCO N-5 Aurangabad tha, wapas wahi gaya",
    ["start point CIDCO N-5, Aurangabad"],
    { at: CHIKALTHANA },
  );
  check("expense: card with legs", e.card && e.card.lines.filter((l) => /→/.test(l.label)).length >= 2);
  if (e.card) {
    const total = e.card.lines.find((l) => l.label === "Total")?.value ?? "";
    check("expense: priced at ₹4/km", /₹4 \(Bike\)/.test(total), total);
    await confirm(e.card);
  }
  const again = await say("aaj ka expense phir se daal do start CIDCO N-5");
  check("expense: same day is not entered twice", !again.drafts.some((d) => d.kind === "travel_expense"));

  // --- 4. Visiting card: front + back together -----------------------------
  console.log("\n════════ 4. Visiting card front + back ════════");
  let front;
  let back;
  try {
    front = await upload("card_front.png");
    back = await upload("card_back.png");
  } catch (err) {
    check("card: upload to Storage", false, String(err));
  }
  if (front && back) {
    const k = await untilCard("saved_contact", "ye visiting card save karo, front aur back dono hai", ["haan save karo"], {
      attachments: [front, back],
    });
    check("card: ONE contact card for two photos", k.card && k.turn.drafts.filter((d) => d.kind === "saved_contact").length === 1);
    if (k.card) {
      check("card: name read", k.card.lines.some((l) => /rahul/i.test(l.value)));
      check("card: front + back noted", k.card.lines.some((l) => /front \+ back/i.test(l.value)));
      await confirm(k.card);
    }
    const lookup = await say("Rahul Verma ka number kya hai?");
    check("card: number found later", /98220\s?12345|9822012345/.test(lookup.reply));
  }

  // --- 5. Delete + undo ---------------------------------------------------
  console.log("\n════════ 5. Delete with confirmation, then undo ════════");
  const d = await untilCard("delete_record", "Exide wala visit delete kar do", ["haan Exide Industries wala hi"]);
  check("delete: card drawn, nothing deleted yet", d.card);
  const beforeConfirm = await list("visits");
  check("delete: visit still there before confirm", beforeConfirm.some((v) => /exide/i.test(v.clientName ?? "")));
  if (d.card) {
    await confirm(d.card);
    const after = await list("visits");
    check("delete: gone after confirm", !after.some((v) => /exide/i.test(v.clientName ?? "")));
    const r = await untilCard("restore_deleted", "galti ho gayi, wo visit wapas lao", ["haan Exide wala wapas lao"]);
    check("undo: restore card drawn", r.card);
    if (r.card) {
      await confirm(r.card);
      const back2 = await list("visits");
      check("undo: visit is back", back2.some((v) => /exide/i.test(v.clientName ?? "")));
    }
  }

  // --- 6. Read-backs ------------------------------------------------------
  console.log("\n════════ 6. Read-backs ════════");
  const lv = await say("aaj kitne visit hue?");
  check("list visits: answers with 2", /\b2\b|two|do /i.test(lv.reply));
  await say("is mahine ka travel kitna hua?");

  // --- 7. What Firestore actually holds -----------------------------------
  console.log("\n════════ 7. Firestore state ════════");
  const visits = await list("visits");
  check("firestore: 2 visits", visits.length === 2, visits.map((v) => `${v.clientName} ${v.dateLabel} pin=${v.lat ?? "none"}`).join(" | "));
  const bajaj = visits.find((v) => /bajaj/i.test(v.clientName ?? ""));
  check("firestore: Bajaj visit has a pin and a follow-up", bajaj && bajaj.lat != null && bajaj.followUpMs > 0);
  const places = await list("places");
  check("firestore: Bajaj saved as a place", places.some((p) => /bajaj/i.test(p.name ?? "")));
  const exp = await list("travelExpenses");
  check("firestore: one travel day", exp.length === 1, exp.map((x) => `${x.totalKm} km ₹${x.totalAmount}, ${x.legs?.length} legs`).join(""));
  const reminders = await list("reminders");
  const prompt = reminders.find((r) => r.subType === "expense_prompt");
  check(
    "firestore: 8 PM expense reminder cancelled after the entry (or none, if after 8 PM)",
    !prompt || prompt.status === "cancelled",
    prompt ? prompt.status : "none",
  );
  const contacts = await myContacts();
  const rahul = contacts.find((c) => /rahul/i.test(c.name ?? ""));
  check("firestore: contact has both card photos", rahul && (rahul.cardImages ?? []).length === 2, rahul ? `${rahul.phone} | ${rahul.notes}` : "missing");
  const trash = await list("trash");
  check("firestore: trash kept a copy", trash.length >= 1);
  const usage = await list("aiUsage");
  const usd = usage.reduce((a, u) => a + (u.costUsd ?? 0), 0);
  check("firestore: AI usage logged per turn with tokens", usage.length >= 8 && usage.every((u) => u.inputTokens > 0), `${usage.length} calls, $${usd.toFixed(4)}`);

  const failed = checks.filter((c) => !c.ok);
  console.log(`\n════════ RESULT: ${checks.length - failed.length}/${checks.length} passed ════════`);
  for (const c of failed) console.log(`FAILED: ${c.name}${c.detail ? ` — ${c.detail}` : ""}`);
  process.exit(failed.length ? 1 : 0);
}

main().catch((e) => {
  console.error("CRASH", e);
  process.exit(2);
});

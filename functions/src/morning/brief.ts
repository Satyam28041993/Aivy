/**
 * The morning brief — what happened overnight, and what today asks of you.
 *
 * Built when the app is opened, not on a schedule, and that is a constraint
 * rather than a preference: the server holds no Google refresh token, only the
 * access token the app forwards with a turn, so nothing here can read Gmail
 * while the phone is asleep. It is therefore built once a day on first open
 * and cached, so opening the app five times before lunch costs one build.
 *
 * The sections are the ones asked for, in the order a morning is actually
 * read: mail that wants an answer, news large enough to matter, the alert
 * digests grouped by subject, today's own commitments, and yesterday's money.
 */

import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { DateTime } from "luxon";

import { gmailSearch, GoogleApiError, type GmailSummaryRow } from "../agent/google/workspace";
import { runWebSearch } from "../webSearch";
import { totalMoney, type MoneyTotals } from "./money";

const MODEL = "gemini-2.5-flash";
const ENDPOINT = `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`;

const ALERTS_SENDER = "googlealerts-noreply@google.com";

export interface BriefSection {
  /** "mail" | "news" | "alerts" | "today" | "money" */
  kind: string;
  title: string;
  items: BriefItem[];
  /** Shown when there is nothing — "Nothing needs an answer." */
  emptyNote?: string;
}

export interface BriefItem {
  headline: string;
  detail?: string;
  /** Grouping label inside a section — the Google Alert term, mostly. */
  group?: string;
  link?: string;
}

export interface MorningBrief {
  dateKey: string;
  builtAtMs: number;
  greeting: string;
  sections: BriefSection[];
  /** What could not be read, said plainly rather than left as a gap. */
  gaps: string[];
}

function dateKeyFor(timezone: string, nowMs = Date.now()): string {
  return DateTime.fromMillis(nowMs, { zone: timezone || "Asia/Kolkata" }).toFormat("yyyy-LL-dd");
}

function briefRef(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("meta").doc("morning_brief");
}

export async function cachedBrief(uid: string, dateKey: string): Promise<MorningBrief | null> {
  try {
    const snap = await briefRef(uid).get();
    const data = snap.data() as MorningBrief | undefined;
    return data && data.dateKey === dateKey ? data : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Gathering
// ---------------------------------------------------------------------------

export interface GatheredInput {
  important: GmailSummaryRow[];
  alerts: GmailSummaryRow[];
  money: MoneyTotals;
  news: Array<{ title: string; snippet: string; link: string }>;
  today: string[];
  gaps: string[];
}

/** Today's own commitments, straight from Firestore — no model involved. */
async function todaysCommitments(uid: string, timezone: string): Promise<string[]> {
  const zone = timezone || "Asia/Kolkata";
  const start = DateTime.now().setZone(zone).startOf("day").toMillis();
  const end = DateTime.now().setZone(zone).endOf("day").toMillis();
  const db = getFirestore();
  const out: string[] = [];

  try {
    const reminders = await db
      .collection("users")
      .doc(uid)
      .collection("reminders")
      .where("status", "==", "pending")
      .where("scheduledTimeMs", "<=", end)
      .orderBy("scheduledTimeMs", "asc")
      .limit(40)
      .get();

    for (const doc of reminders.docs) {
      const r = doc.data();
      const ms = Number(r.scheduledTimeMs ?? 0);
      if (!ms) {
        continue;
      }
      const when = DateTime.fromMillis(ms, { zone });
      // Anything still open from before today belongs in today's list: a task
      // missed on Friday does not stop being owed on Monday.
      const label = ms < start ? `overdue since ${when.toFormat("d LLL")}` : when.toFormat("h:mm a");
      const who = `${r.clientName ?? ""}`.trim();
      out.push(
        `${r.title ?? "Reminder"} — ${label}${who ? ` (${who})` : ""} [${r.subType ?? r.type ?? "task"}]`,
      );
    }
  } catch (e) {
    logger.warn("brief: reminders read failed", {
      err: e instanceof Error ? e.message : String(e),
    });
  }

  try {
    const quotes = await db
      .collection("users")
      .doc(uid)
      .collection("quotations")
      .where("status", "==", "pending")
      .where("followUpDateMs", "<=", end)
      .limit(20)
      .get();
    for (const doc of quotes.docs) {
      const q = doc.data();
      out.push(`Quotation follow-up: ${q.clientName ?? "client"} — ₹${q.amount ?? 0}`);
    }
  } catch (e) {
    logger.warn("brief: quotations read failed", {
      err: e instanceof Error ? e.message : String(e),
    });
  }

  return out;
}

export async function gather(
  uid: string,
  timezone: string,
  googleToken: string | null,
): Promise<GatheredInput> {
  const gaps: string[] = [];
  let important: GmailSummaryRow[] = [];
  let alerts: GmailSummaryRow[] = [];
  let money: MoneyTotals = {
    credited: 0,
    spent: 0,
    creditCount: 0,
    spendCount: 0,
    lines: [],
  };

  if (googleToken) {
    // Three slices of one mailbox, in parallel — the brief is on the critical
    // path of opening the app, so they must not queue behind each other.
    const [imp, alr, mny] = await Promise.all([
      gmailSearch(
        googleToken,
        `newer_than:2d -from:${ALERTS_SENDER} -category:promotions -category:social`,
        20,
      ).catch((e) => {
        gaps.push(gmailGap(e, "your inbox"));
        return [] as GmailSummaryRow[];
      }),
      gmailSearch(googleToken, `newer_than:2d from:${ALERTS_SENDER}`, 25).catch(() => {
        gaps.push("Google Alerts could not be read.");
        return [] as GmailSummaryRow[];
      }),
      gmailSearch(
        googleToken,
        "newer_than:2d (debited OR credited OR UPI OR transaction OR payment)",
        25,
      ).catch(() => {
        gaps.push("Bank and UPI mail could not be read.");
        return [] as GmailSummaryRow[];
      }),
    ]);
    important = imp;
    alerts = alr;
    money = totalMoney(mny);
  } else {
    gaps.push(
      "Google is not connected on this device, so mail, alerts and money are missing.",
    );
  }

  let news: GatheredInput["news"] = [];
  try {
    const res = await runWebSearch("top news headlines India today");
    news = (res.results ?? []).slice(0, 6).map((r) => ({
      title: r.title ?? "",
      snippet: r.snippet ?? "",
      link: r.link ?? "",
    }));
  } catch {
    gaps.push("News could not be fetched.");
  }

  const today = await todaysCommitments(uid, timezone);
  return { important, alerts, money, news, today, gaps };
}

function gmailGap(e: unknown, what: string): string {
  if (e instanceof GoogleApiError && e.isAuth) {
    return `Google sign-in expired, so ${what} could not be read.`;
  }
  return `Could not read ${what}.`;
}

// ---------------------------------------------------------------------------
// Writing it
// ---------------------------------------------------------------------------

const BRIEF_INSTRUCTION = `You write one person's morning brief. Be brief, concrete and in English.

You are given raw material. Turn it into sections. Rules that matter:

- Judge importance yourself. Most mail is noise: newsletters, receipts, alerts,
  "your app is installed". Only surface mail a person would want to act on or
  would regret missing — someone waiting on a reply, an interview, a client, a
  bill due, a delivery problem. If nothing qualifies, say so rather than
  padding the list.
- News: only genuinely large stories, two or three at most. A product launch is
  not news. If nothing is big, return no news items at all.
- Google Alerts: group by the alert term, which is in the subject after
  "Google Alert -". One line per term saying what actually came up in it, not a
  list of every headline. This is the section he reads to decide what to ask
  about, so it must be scannable.
- Today: one line per commitment, time first. Say plainly if the day is empty.
- Money: use ONLY the totals given. Never state a rupee figure that is not in
  the input. If both totals are zero, say nothing was found.

Answer with JSON only, no prose around it, in exactly this shape:
{"greeting":"one short line","sections":[{"kind":"mail|news|alerts|today|money","title":"...","emptyNote":"...","items":[{"headline":"...","detail":"...","group":"...","link":"..."}]}]}

Keep every section present even when empty — set items to [] and write
emptyNote. Omit detail, group and link when there is nothing to put in them.`;

function briefPrompt(input: GatheredInput, nowLabel: string): string {
  const mail = input.important
    .map((m) => `- from ${m.from} | ${m.subject} | ${m.snippet.slice(0, 200)}`)
    .join("\n");
  const alerts = input.alerts
    .map((m) => `- ${m.subject} | ${m.snippet.slice(0, 300)}`)
    .join("\n");
  const news = input.news.map((n) => `- ${n.title} | ${n.snippet} | ${n.link}`).join("\n");
  const today = input.today.map((t) => `- ${t}`).join("\n");

  return `Now: ${nowLabel}

## Mail from the last two days
${mail || "(none)"}

## Google Alert digests
${alerts || "(none)"}

## Candidate news
${news || "(none)"}

## Today's commitments
${today || "(nothing scheduled)"}

## Money in the last two days, already totalled — do not compute your own
Credited: ₹${Math.round(input.money.credited)} across ${input.money.creditCount} mail(s)
Spent: ₹${Math.round(input.money.spent)} across ${input.money.spendCount} mail(s)`;
}

function parseBrief(raw: string): { greeting: string; sections: BriefSection[] } | null {
  // The model is asked for bare JSON and usually obliges, but a stray ```json
  // fence should not cost the user their whole brief.
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) {
    return null;
  }
  try {
    const parsed = JSON.parse(raw.slice(start, end + 1)) as {
      greeting?: unknown;
      sections?: unknown;
    };
    const sections = Array.isArray(parsed.sections)
      ? parsed.sections
          .filter((s): s is Record<string, unknown> => s != null && typeof s === "object")
          .map((s) => ({
            kind: `${s.kind ?? "other"}`,
            title: `${s.title ?? ""}`,
            emptyNote: s.emptyNote ? `${s.emptyNote}` : undefined,
            items: Array.isArray(s.items)
              ? s.items
                  .filter((i): i is Record<string, unknown> => i != null && typeof i === "object")
                  .map((i) => ({
                    headline: `${i.headline ?? ""}`.trim(),
                    detail: i.detail ? `${i.detail}`.trim() : undefined,
                    group: i.group ? `${i.group}`.trim() : undefined,
                    link: i.link ? `${i.link}`.trim() : undefined,
                  }))
                  .filter((i) => i.headline.length > 0)
              : [],
          }))
      : [];
    return { greeting: `${parsed.greeting ?? "Good morning."}`, sections };
  } catch {
    return null;
  }
}

export async function buildBrief(opts: {
  uid: string;
  timezone: string;
  googleToken: string | null;
  geminiKey: string;
  nowMs?: number;
}): Promise<MorningBrief> {
  const nowMs = opts.nowMs ?? Date.now();
  const zone = opts.timezone || "Asia/Kolkata";
  const input = await gather(opts.uid, zone, opts.googleToken);
  const nowLabel = DateTime.fromMillis(nowMs, { zone }).toFormat("cccc, d LLLL, h:mm a");

  let written: { greeting: string; sections: BriefSection[] } | null = null;
  try {
    const res = await fetch(`${ENDPOINT}?key=${encodeURIComponent(opts.geminiKey)}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: BRIEF_INSTRUCTION }] },
        contents: [{ role: "user", parts: [{ text: briefPrompt(input, nowLabel) }] }],
        generationConfig: { temperature: 0.3, responseMimeType: "application/json" },
      }),
    });
    if (res.ok) {
      const body = (await res.json()) as {
        candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
      };
      const text = body.candidates?.[0]?.content?.parts?.map((p) => p.text ?? "").join("") ?? "";
      written = parseBrief(text);
    } else {
      logger.error("brief: model refused", { status: res.status });
    }
  } catch (e) {
    logger.error("brief: model call failed", {
      err: e instanceof Error ? e.message : String(e),
    });
  }

  // A failed summary must not cost the sections that need no model at all.
  if (!written) {
    input.gaps.push("Could not summarise this morning — showing what is scheduled only.");
    written = {
      greeting: "Good morning.",
      sections: [
        {
          kind: "today",
          title: "Today",
          items: input.today.map((t) => ({ headline: t })),
          emptyNote: "Nothing scheduled.",
        },
      ],
    };
  }

  const brief: MorningBrief = {
    dateKey: dateKeyFor(zone, nowMs),
    builtAtMs: nowMs,
    greeting: written.greeting,
    sections: written.sections,
    gaps: input.gaps,
  };

  try {
    await briefRef(opts.uid).set(brief);
  } catch (e) {
    logger.warn("brief: could not cache", { err: e instanceof Error ? e.message : String(e) });
  }
  return brief;
}

export { dateKeyFor };

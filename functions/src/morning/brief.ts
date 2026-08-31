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
 * digests grouped by subject, and today's own commitments.
 *
 * Money was here and has been taken out on request — the reading code and its
 * tests are kept, since it is coming back once the shape of it is settled.
 *
 * Work — tasks and projects — is added after the model has written the rest,
 * and never passed through it. Those sections are counts and dates already
 * correct in Firestore, so handing them to a model can only make them wrong.
 * Twice now a section has been lost because model output did not come back in
 * the shape the parser expected, and neither time was the reader told. What
 * cannot be summarised wrongly should not be summarised.
 */

import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { DateTime } from "luxon";

import { gmailSearch, GoogleApiError, type GmailSummaryRow } from "../agent/google/workspace";
import {
  dueOf,
  isLive,
  kindOf,
  listItems,
  listProjects,
  summarise,
} from "../agent/projectStore";
import { runWebSearch } from "../webSearch";

const MODEL = "gemini-2.5-flash";
const ENDPOINT = `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`;

const ALERTS_SENDER = "googlealerts-noreply@google.com";

export interface BriefSection {
  /** "mail" | "news" | "alerts" | "today" */
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
  /**
   * "late" | "due" | "ok" — colours the line's marker and nothing else. Late
   * work has to be findable at a glance in a card that is otherwise all one
   * weight, and a person scanning their morning reads colour before words.
   */
  tone?: string;
  /**
   * The project or task this line stands for, so tapping it can open the whole
   * thing. Only the work sections carry it; a mail or a headline has a link
   * instead.
   */
  refId?: string;
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
      // A task's own deadline and check-in have a section of their own below.
      // Listing them here too would show the same job twice in one card.
      const subType = `${r.subType ?? ""}`;
      if (subType === "task_due" || subType === "task_nudge") {
        continue;
      }
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
  /** What the request came from, so a missing token can be explained. */
  platform: string = "",
): Promise<GatheredInput> {
  const gaps: string[] = [];
  let important: GmailSummaryRow[] = [];
  let alerts: GmailSummaryRow[] = [];

  if (googleToken) {
    // Two slices of one mailbox, in parallel — the brief is on the critical
    // path of opening the app, so they must not queue behind each other.
    // Transaction and bank mail is excluded at the query rather than left for
    // the model to reject: it is the loudest noise in this inbox and there is
    // no version of it worth a line in the morning.
    const [imp, alr] = await Promise.all([
      gmailSearch(
        googleToken,
        `newer_than:2d -from:${ALERTS_SENDER} -category:promotions -category:social ` +
          "-from:notifications@github.com -from:noreply@github.com " +
          "-subject:(UPI OR debited OR credited OR OTP OR statement OR EMI)",
        20,
      ).catch((e) => {
        gaps.push(gmailGap(e, "your inbox"));
        return [] as GmailSummaryRow[];
      }),
      gmailSearch(googleToken, `newer_than:2d from:${ALERTS_SENDER}`, 25).catch(() => {
        gaps.push("Google Alerts could not be read.");
        return [] as GmailSummaryRow[];
      }),
    ]);
    important = imp;
    alerts = alr;
  } else {
    // "Not connected" reads as something the user forgot to do. On the web
    // there is nothing to do — Gmail needs the Android sign-in — and telling
    // them to go and connect it would send them looking for a button that
    // does not exist.
    gaps.push(
      platform === "web"
        ? "Mail and Google Alerts need the Android app; the browser cannot read them."
        : "Google is not connected on this device, so mail and alerts are missing.",
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
  return { important, alerts, news, today, gaps };
}

function gmailGap(e: unknown, what: string): string {
  if (e instanceof GoogleApiError && e.isAuth) {
    return `Google sign-in expired, so ${what} could not be read.`;
  }
  return `Could not read ${what}.`;
}

// ---------------------------------------------------------------------------
// Work — tasks and projects, straight from Firestore
// ---------------------------------------------------------------------------

/** How a deadline reads on the morning it is being read. */
export function dueWords(dueMs: number, zone: string, nowMs: number): { text: string; tone?: string } {
  if (dueMs <= 0) {
    return { text: "no date" };
  }
  const due = DateTime.fromMillis(dueMs, { zone }).startOf("day");
  const today = DateTime.fromMillis(nowMs, { zone }).startOf("day");
  const days = Math.round(due.diff(today, "days").days);

  if (days < 0) {
    const n = Math.abs(days);
    return { text: n === 1 ? "1 day late" : `${n} days late`, tone: "late" };
  }
  if (days === 0) {
    return { text: "due today", tone: "due" };
  }
  if (days === 1) {
    return { text: "due tomorrow", tone: "due" };
  }
  return { text: `due ${DateTime.fromMillis(dueMs, { zone }).toFormat("d LLL")}` };
}

function joinDetail(parts: Array<string | null | undefined>): string | undefined {
  const kept = parts.map((p) => (p ?? "").trim()).filter(Boolean);
  return kept.length > 0 ? kept.join(" · ") : undefined;
}

/**
 * The two sections that answer "what is on me today" without a model.
 *
 * Tasks are ordered late first, then soonest — which is the order they will be
 * worried about, not the order they were created. Projects are summarised by
 * count rather than listed item by item: a project with fourteen open items is
 * not a morning read, and `project_status` exists for when it is.
 */
export async function workSections(
  uid: string,
  timezone: string,
  nowMs: number,
  gaps: string[],
): Promise<BriefSection[]> {
  const zone = timezone || "Asia/Kolkata";
  let live: Awaited<ReturnType<typeof listProjects>> = [];
  try {
    live = (await listProjects(uid, { limit: 60 })).filter(isLive);
  } catch (e) {
    logger.warn("brief: projects read failed", {
      err: e instanceof Error ? e.message : String(e),
    });
    gaps.push("Tasks and projects could not be read.");
    return [];
  }

  const taskRows: Array<{ item: BriefItem; sortKey: number }> = [];
  const projectRows: Array<{ item: BriefItem; sortKey: number }> = [];

  for (const p of live) {
    let items: Awaited<ReturnType<typeof listItems>> = [];
    try {
      items = await listItems(uid, p.id, 100);
    } catch {
      // One unreadable project is not worth losing the section over.
      items = [];
    }
    const sum = summarise(p, items, nowMs);
    const openCount = sum.open.length + sum.waiting.length;

    if (kindOf(p) === "task") {
      const due = dueOf(p);
      const when = dueWords(due, zone, nowMs);
      taskRows.push({
        item: {
          refId: p.id,
          headline: p.name,
          detail: joinDetail([
            p.clientName || null,
            when.text,
            openCount > 0 ? `${openCount} step${openCount === 1 ? "" : "s"} left` : null,
          ]),
          tone: when.tone,
        },
        sortKey: due > 0 ? due : Number.MAX_SAFE_INTEGER,
      });
      continue;
    }

    const nextDue = sum.next ? dueWords(sum.next.dueMs, zone, nowMs) : null;
    projectRows.push({
      item: {
        refId: p.id,
        headline: p.name,
        detail:
          joinDetail([
            p.clientName || null,
            sum.overdue.length > 0 ? `${sum.overdue.length} late` : null,
            sum.open.length > 0 ? `${sum.open.length} pending` : null,
            sum.waiting.length > 0 ? `${sum.waiting.length} waiting on them` : null,
            sum.next ? `next: ${sum.next.title} (${nextDue?.text})` : null,
          ]) ?? "all clear",
        tone: sum.overdue.length > 0 ? "late" : undefined,
      },
      sortKey: sum.next?.dueMs && sum.next.dueMs > 0 ? sum.next.dueMs : Number.MAX_SAFE_INTEGER,
    });
  }

  // Late work sorts to the top of the tasks list by having the smallest date.
  taskRows.sort((a, b) => a.sortKey - b.sortKey);
  projectRows.sort((a, b) => a.sortKey - b.sortKey);

  return [
    {
      kind: "tasks",
      title: "Your tasks",
      items: taskRows.slice(0, 8).map((r) => r.item),
      emptyNote: "Nothing running. Tell me about one and I will track it.",
    },
    {
      kind: "projects",
      title: "Projects",
      items: projectRows.slice(0, 6).map((r) => r.item),
      emptyNote: "No projects open.",
    },
  ];
}

// ---------------------------------------------------------------------------
// Writing it
// ---------------------------------------------------------------------------

const BRIEF_INSTRUCTION = `You write one person's morning brief. Be concrete and short.

## Language
Open with a greeting that matches the time of day given below — not "Good
morning" in the evening.

Section headings and the mail section: English.
**News and Google Alerts: Hindi** — plain spoken Hindi in Devanagari, the way you
would explain something to a friend, not translated newspaper Hindi.

## Mail — the hard part is what to leave out
Almost nothing qualifies. Include a mail only if a person would act on it today
or would be worse off for missing it: a real person waiting on a reply, a client,
an interview or offer, a bill actually due, a delivery or order problem, money
someone owes.

Never include, no matter how urgent the subject line sounds:
- transaction alerts of any kind — "UPI Transaction Successful", "UPI
  Transaction FAILED", debit and credit alerts, payment receipts
- bank marketing and loan mail — "Important Update on Your Bank Loan Dues",
  offers, statements, EMI notices
- anything automated from a service: GitHub, CI or build failures, tokens
  expiring, deploy notices, "your app is installed", password and OTP mail
- newsletters, promotions, job alerts, social notifications, Google Alerts

Those five examples are real mail this person did not want. If nothing survives
the test, return an empty list and say so in emptyNote. An empty mail section is
the correct answer most mornings, and far better than five lines of noise.

## Google Alerts — this is the section he actually reads
He runs alerts on his trade and his interests: labels, printing, packaging,
marketing, AI tools, startups, government schemes. This section is how he
decides what to look into, so it must never come back empty when alert mail
exists.

**Every alert term in the mail gets an entry.** Twenty terms means twenty
entries. Do not select, do not skip, do not decide a term is unworthy — that
judgement is his, and this section exists to let him make it.

Each entry uses exactly two fields: "group" is the term, spelled as it appears
in the subject after "Google Alert - ", and **"headline" is your Hindi
explanation** — the sentences themselves. Leave "detail" out of alert entries.

Under each term, write in Hindi what the articles are about and why it might
matter to him. Alert snippets are short by nature — a headline and a line or
two — and that is what you have to work with. Expand it into a real sentence
that carries meaning: what happened, who did it, what it changes.

Bad:  "Canva ke hardest year par reports."          (the subject line again)
Bad:  "Canva ke baare mein articles publish hue."   (says nothing at all)
Good: "Canva ka kehna hai ki AI ke bhaari kharche ki wajah se is saal unki
       valuation kam hui. Ek article ye bhi poochhta hai ki freelance design ke
       liye ab Canva akela kaafi hai ya nahi."

When several articles under one term say the same thing, say it once. When a
snippet really gives you nothing beyond its headline, translate the headline
into plain Hindi and say what it appears to be about — one honest line beats
dropping the term, because a missing term looks like a fault.

## News
Only genuinely large stories, two or three at most, in Hindi. A product launch
or a company blog post is not news. If nothing is big, return no items.

## Today
One line per commitment, time first, in English. Say plainly if the day is empty.

## Shape
Answer with JSON only, no prose around it:
{"greeting":"one short line","sections":[{"kind":"mail|news|alerts|today","title":"...","emptyNote":"...","items":[{"headline":"...","detail":"...","group":"...","link":"..."}]}]}

Sections in this order: mail, news, alerts, today. **All four must be in your
answer every single time**, even when a section has nothing: give it items [] and
an emptyNote saying so. Dropping a section is never correct — the reader cannot
tell an empty section from a broken one. Omit detail, group and link when there
is nothing to put in them. Do not add a money section.`;

function briefPrompt(input: GatheredInput, nowLabel: string): string {
  const mail = input.important
    .map((m) => `- from ${m.from} | ${m.subject} | ${m.snippet.slice(0, 200)}`)
    .join("\n");
  // Alerts get the whole snippet: the section is judged on whether it explains
  // what the articles say, and a summary cannot be written from a truncated one.
  const alerts = input.alerts.map((m) => `- ${m.subject} | ${m.snippet}`).join("\n");
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
${today || "(nothing scheduled)"}`;
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
                  .map((i) => {
                    const headline = `${i.headline ?? ""}`.trim();
                    const detail = `${i.detail ?? ""}`.trim();
                    return {
                      // An item whose words are all in detail is still an
                      // item. Requiring a headline threw away every Google
                      // Alert entry, because the model put the term in group
                      // and the explanation in detail — which is exactly what
                      // it was asked for.
                      headline: headline || detail,
                      detail: headline && detail ? detail : undefined,
                      group: i.group ? `${i.group}`.trim() : undefined,
                      link: i.link ? `${i.link}`.trim() : undefined,
                    };
                  })
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
  platform?: string;
  nowMs?: number;
}): Promise<MorningBrief> {
  const nowMs = opts.nowMs ?? Date.now();
  const zone = opts.timezone || "Asia/Kolkata";
  const input = await gather(opts.uid, zone, opts.googleToken, opts.platform ?? "");
  const nowLabel = DateTime.fromMillis(nowMs, { zone }).toFormat("cccc, d LLLL, h:mm a");

  let written: { greeting: string; sections: BriefSection[] } | null = null;
  try {
    const res = await fetch(`${ENDPOINT}?key=${encodeURIComponent(opts.geminiKey)}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: BRIEF_INSTRUCTION }] },
        contents: [{ role: "user", parts: [{ text: briefPrompt(input, nowLabel) }] }],
        generationConfig: {
          temperature: 0.3,
          responseMimeType: "application/json",
          // Twenty alert terms explained in Hindi is a long answer, and a
          // truncated one parses as no alerts at all.
          maxOutputTokens: 8192,
        },
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

  // Which of the two happened is invisible from the screen: no alert mail
  // arrived, or alert mail arrived and came back out as nothing. Saying so
  // turns a silent empty section into something answerable.
  const alertItems = written.sections
    .filter((s) => s.kind === "alerts")
    .reduce((n, s) => n + s.items.length, 0);
  if (input.alerts.length > 0 && alertItems === 0) {
    input.gaps.push(
      `${input.alerts.length} alert mail(s) were read but none were summarised.`,
    );
  }

  // Appended, not merged: whatever the model did or failed to do with the rest
  // of the morning, what is on him today is read from Firestore and is right.
  const work = await workSections(opts.uid, zone, nowMs, input.gaps);

  const brief: MorningBrief = {
    dateKey: dateKeyFor(zone, nowMs),
    builtAtMs: nowMs,
    greeting: written.greeting,
    sections: [...written.sections, ...work],
    gaps: input.gaps,
  };

  try {
    await briefRef(opts.uid).set(brief);
  } catch (e) {
    logger.warn("brief: could not cache", { err: e instanceof Error ? e.message : String(e) });
  }
  return brief;
}

export { dateKeyFor, parseBrief };

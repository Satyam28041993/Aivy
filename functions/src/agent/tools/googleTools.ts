/**
 * Google Workspace tools — calendar, mail, sheets, contacts.
 *
 * Same split as the rest of the agent: reading answers immediately, writing
 * proposes a card. Sending a mail or blocking someone's calendar is exactly the
 * kind of thing that must not happen on a misheard sentence, so those go
 * through the same confirm step as a payment entry.
 *
 * Every tool here needs `ctx.googleToken`. When it is absent — the web build,
 * or a user who never granted the scopes — the tool fails with a plain sentence
 * the model can pass on, rather than silently doing nothing.
 */

import { DateTime } from "luxon";
import { getFirestore } from "firebase-admin/firestore";

import { createDraft } from "../draftStore";
import { formatWhenLabel, resolveWhen, type DayPeriod, type WhenTense } from "../dateResolve";
import { isWindowName, resolveWindow, type WindowName } from "../timeWindow";
import {
  calendarListEvents,
  gmailListRecent,
  GoogleApiError,
  peopleSearch,
} from "../google/workspace";
import type { DraftCardLine } from "../draftTypes";
import { dataResult, draftResult, fail, type ToolContext, type ToolResult } from "../toolTypes";

const NO_TOKEN =
  "Google abhi connect nahi hai. Android app me More → Allow Google extras se " +
  "permission de dijiye (web par ye kaam nahi karta).";

function str(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

function tokenOf(ctx: ToolContext): string | null {
  const t = ctx.googleToken;
  return typeof t === "string" && t.trim() ? t.trim() : null;
}

function tenseOf(raw: unknown): WhenTense {
  return raw === "past" ? "past" : "future";
}

function periodOf(raw: unknown): DayPeriod | null {
  const v = str(raw).toLowerCase();
  return v === "morning" || v === "afternoon" || v === "evening" || v === "night" ? v : null;
}

function windowOf(raw: unknown, fallback: WindowName = "today"): WindowName {
  return isWindowName(raw) ? raw : fallback;
}

/** Turns a Google failure into something the model can say out loud. */
function googleFailure(e: unknown): ToolResult {
  if (e instanceof GoogleApiError) {
    return fail(e.isAuth ? "invalid" : "failed", e.hindiMessage);
  }
  return fail("failed", "Google se baat nahi ho paayi.");
}

// ---------------------------------------------------------------------------
// create_calendar_event  (write → draft)
// ---------------------------------------------------------------------------

export async function createCalendarEventTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  if (!tokenOf(ctx)) {
    return fail("failed", NO_TOKEN);
  }
  const summary = str(args.summary);
  if (!summary) {
    return fail("needs_detail", "Calendar par kya likhun?");
  }
  const whenPhrase = str(args.when_phrase);
  if (!whenPhrase) {
    return fail("needs_date", "Kab ka event hai?");
  }
  const when = resolveWhen({
    phrase: whenPhrase,
    timezone: ctx.timezone,
    nowIso: ctx.nowIso,
    tense: tenseOf(args.when_tense),
    period: periodOf(args.day_period),
  });
  if (!when.iso || when.epochMs == null) {
    return fail("needs_date", `"${whenPhrase}" se date samajh nahi aayi — dobara bataiye.`);
  }

  const duration = typeof args.duration_minutes === "number"
    ? Math.max(15, Math.min(12 * 60, args.duration_minutes))
    : 60;
  const description = str(args.description) || null;
  const attendees = Array.isArray(args.attendee_emails)
    ? args.attendee_emails.map((e) => str(e)).filter((e) => e.includes("@"))
    : [];

  const lines: DraftCardLine[] = [
    { label: "Event", value: summary },
    { label: "Kab", value: when.label ?? whenPhrase },
    { label: "Kitni der", value: `${duration} min` },
  ];
  if (attendees.length) {
    lines.push({ label: "Invite", value: attendees.join(", ") });
  }
  if (description) {
    lines.push({ label: "Detail", value: description });
  }

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "calendar_event",
    title: "Google Calendar",
    icon: "🗓️",
    lines,
    chatId: ctx.chatId,
    data: {
      kind: "calendar_event",
      summary,
      description,
      whenIso: when.iso,
      whenMs: when.epochMs,
      whenLabel: when.label ?? whenPhrase,
      durationMinutes: duration,
      timezone: ctx.timezone,
      attendeeEmails: attendees,
    },
  });

  return draftResult(
    draft,
    "Calendar event ka draft taiyaar hai — confirm hone par hi Google Calendar me jaayega.",
  );
}

// ---------------------------------------------------------------------------
// send_email  (write → draft)
// ---------------------------------------------------------------------------

export async function sendEmailTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const token = tokenOf(ctx);
  if (!token) {
    return fail("failed", NO_TOKEN);
  }
  const subject = str(args.subject);
  const body = str(args.body);
  if (!body) {
    return fail("needs_detail", "Mail me likhna kya hai?");
  }

  let to = str(args.to);
  let toName: string | null = null;

  // Only a name was given — look the address up rather than guessing at one.
  if (!to.includes("@")) {
    const lookup = to || str(args.to_name);
    if (!lookup) {
      return fail("needs_detail", "Mail kisko bhejna hai?");
    }
    let contacts;
    try {
      contacts = await peopleSearch(token, lookup);
    } catch (e) {
      return googleFailure(e);
    }
    const withEmail = contacts.filter((c) => c.emails.length > 0);
    if (withEmail.length === 0) {
      return fail(
        "client_not_found",
        `"${lookup}" ka email contacts me nahi mila — address bata dijiye.`,
      );
    }
    if (withEmail.length > 1) {
      return fail(
        "needs_client_choice",
        `"${lookup}" se ek se zyada contact match hue — kiska?`,
        withEmail.slice(0, 5).map((c) => ({
          id: c.emails[0]!,
          label: `${c.name} — ${c.emails[0]}`,
        })),
      );
    }
    to = withEmail[0]!.emails[0]!;
    toName = withEmail[0]!.name;
  }

  const lines: DraftCardLine[] = [
    { label: "Kisko", value: toName ? `${toName} <${to}>` : to },
    { label: "Subject", value: subject || "(bina subject)" },
    { label: "Mail", value: body.length > 400 ? `${body.slice(0, 400)}…` : body },
  ];

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "email",
    title: "Email",
    icon: "✉️",
    lines,
    chatId: ctx.chatId,
    data: { kind: "email", to, toName, subject, body },
  });

  return draftResult(
    draft,
    "Mail draft taiyaar hai — user ke confirm karne par hi jaayega. Padhkar sunaa dijiye.",
  );
}

// ---------------------------------------------------------------------------
// append_sheet_row  (write → draft)
// ---------------------------------------------------------------------------

export async function appendSheetRowTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  if (!tokenOf(ctx)) {
    return fail("failed", NO_TOKEN);
  }
  const cells = Array.isArray(args.cells)
    ? args.cells.map((c) => (c == null ? "" : String(c)))
    : [];
  if (cells.length === 0) {
    return fail("needs_detail", "Sheet me kya likhna hai?");
  }

  const explicitId = str(args.spreadsheet_id) || null;
  const tab = str(args.sheet_tab) || "Sheet1";

  // Resolve the default now, so the card can say which sheet it is going to
  // instead of "the default one".
  let targetId = explicitId;
  let targetLabel = explicitId ? explicitId : "";
  if (!targetId) {
    const snap = await getFirestore()
      .collection("users")
      .doc(ctx.uid)
      .collection("meta")
      .doc("google_prefs")
      .get();
    const saved = str(snap.data()?.defaultSpreadsheetId);
    if (!saved) {
      return fail(
        "needs_detail",
        "Koi default Google Sheet set nahi hai — More → Google settings me sheet ID daal dijiye, " +
          "ya sheet ka link bhej dijiye.",
      );
    }
    targetId = saved;
    targetLabel = "default sheet";
  }

  const lines: DraftCardLine[] = [
    { label: "Sheet", value: targetLabel || targetId },
    { label: "Tab", value: tab },
    { label: "Row", value: cells.join(" | ") },
  ];

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "sheet_row",
    title: "Google Sheet",
    icon: "📊",
    lines,
    chatId: ctx.chatId,
    data: { kind: "sheet_row", spreadsheetId: targetId, tab, cells },
  });

  return draftResult(draft, "Sheet row ka draft taiyaar hai — confirm par likhi jaayegi.");
}

// ---------------------------------------------------------------------------
// list_calendar_events  (read)
// ---------------------------------------------------------------------------

export async function listCalendarEventsTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const token = tokenOf(ctx);
  if (!token) {
    return fail("failed", NO_TOKEN);
  }
  const name = windowOf(args.window, "today");
  const win = resolveWindow(name === "all" ? "this_week" : name, ctx.timezone, ctx.nowIso);

  let rows;
  try {
    rows = await calendarListEvents(token, {
      timeMinIso: new Date(win.startMs).toISOString(),
      timeMaxIso: new Date(win.endMs).toISOString(),
      maxResults: 25,
    });
  } catch (e) {
    return googleFailure(e);
  }

  if (rows.length === 0) {
    return dataResult({ window: win.label, count: 0, events: [] });
  }

  return dataResult({
    window: win.label,
    count: rows.length,
    events: rows.map((r) => ({
      title: r.summary,
      when: r.allDay
        ? "poora din"
        : DateTime.fromISO(r.startIso, { zone: ctx.timezone }).isValid
          ? formatWhenLabel(DateTime.fromISO(r.startIso, { zone: ctx.timezone }), true)
          : r.startIso,
      location: r.location || undefined,
    })),
  });
}

// ---------------------------------------------------------------------------
// list_recent_emails  (read)
// ---------------------------------------------------------------------------

export async function listRecentEmailsTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const token = tokenOf(ctx);
  if (!token) {
    return fail("failed", NO_TOKEN);
  }
  let rows;
  try {
    rows = await gmailListRecent(token, {
      maxResults: typeof args.limit === "number" ? args.limit : 8,
      query: str(args.query) || undefined,
    });
  } catch (e) {
    return googleFailure(e);
  }
  return dataResult({
    count: rows.length,
    emails: rows.map((r) => ({
      from: r.from,
      subject: r.subject,
      snippet: r.snippet.slice(0, 200),
      when: r.receivedMs
        ? formatWhenLabel(DateTime.fromMillis(r.receivedMs, { zone: ctx.timezone }), true)
        : "",
    })),
  });
}

// ---------------------------------------------------------------------------
// find_contact  (read)
// ---------------------------------------------------------------------------

export async function findContactTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const token = tokenOf(ctx);
  if (!token) {
    return fail("failed", NO_TOKEN);
  }
  const q = str(args.query);
  if (!q) {
    return fail("needs_detail", "Kiska contact dhoondhna hai?");
  }
  let rows;
  try {
    rows = await peopleSearch(token, q);
  } catch (e) {
    return googleFailure(e);
  }
  if (rows.length === 0) {
    return fail("nothing_found", `"${q}" naam ka koi contact nahi mila.`);
  }
  return dataResult({
    count: rows.length,
    contacts: rows.slice(0, 8).map((r) => ({
      name: r.name,
      email: r.emails[0] ?? "",
      phone: r.phones[0] ?? "",
    })),
  });
}

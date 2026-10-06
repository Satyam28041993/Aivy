/**
 * The DSR: recording a client visit, adding its follow-up, and reading visits
 * back.
 *
 * The conversation the user asked for is: "visit record karo" → they give the
 * client, who they met, what was discussed and where it stands → Aivy asks for
 * whatever is missing → one card → confirm writes the visit to Aivy and to the
 * DSR sheet → Aivy asks whether to set a follow-up → if yes, the date, on a
 * second card. `record_visit` refuses to draw the card while the essentials
 * are missing, so the cross-questioning is enforced here rather than hoped for
 * in the prompt.
 */

import { DateTime } from "luxon";

import { createDraft } from "../draftStore";
import { resolveWhen, type DayPeriod } from "../dateResolve";
import { nearestPlaceLabel, reverseGeocode } from "../google/maps";
import type { DraftCardLine } from "../draftTypes";
import { dataResult, draftResult, fail, type ToolContext, type ToolResult } from "../toolTypes";
import { referenceClient } from "./writeTools";
import { dsrSheetLink, getVisit, latestVisit, listVisits, sheetDate } from "../visitStore";

function str(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

function periodOf(raw: unknown): DayPeriod | null {
  const v = str(raw).toLowerCase();
  return v === "morning" || v === "afternoon" || v === "evening" || v === "night" ? v : null;
}

/**
 * Google answers a pin with a plus code first ("R6VQ+95C, Bajaj Nagar, …"),
 * which means nothing on a report the company reads.
 */
export function stripPlusCode(label: string): string {
  return label.replace(/^\s*[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}\s*,?\s*/i, "").trim();
}

export const VISIT_TYPES = ["New", "Follow-up", "Demo", "Service", "Payment collection", "Other"];

/** Fields worth asking about before the card is drawn, in the order to ask. */
export function missingVisitDetails(args: Record<string, unknown>): string[] {
  const missing: string[] = [];
  if (!str(args.contact_person)) missing.push("who they met (contact person)");
  if (!str(args.products) && !str(args.discussion)) missing.push("what was discussed / which products");
  if (!str(args.status) && !str(args.next_step)) missing.push("where it stands (status or next step)");
  return missing;
}

// ---------------------------------------------------------------------------
// record_visit
// ---------------------------------------------------------------------------

export async function recordVisitTool(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const clientName = str(args.client_name);
  if (!clientName) {
    return fail("needs_detail", "Which client / company did they visit?");
  }

  // Cross-question once for the missing essentials. The model sets
  // details_complete when the user has answered or said there is nothing more,
  // so a skipped field never loops.
  // The user asked to be asked, every time, whether the phone is standing at
  // the client — yes keeps the pin (and the client becomes a saved place),
  // no keeps nothing. Asked alongside any missing details, in one message.
  const askPin = Boolean(ctx.coords) && typeof args.at_client_location !== "boolean";
  const missing = args.details_complete === true ? [] : missingVisitDetails(args);
  if (askPin) {
    missing.push("whether they are at the client's place right now, so its location can be saved (yes / no)");
  }
  if (missing.length > 0) {
    return fail(
      "needs_detail",
      `Before saving the visit, ask in one message for: ${missing.join("; ")}. ` +
        "Pass at_client_location=true/false from their answer. " +
        "If they say there is nothing more, call record_visit again with details_complete=true.",
    );
  }

  const resolved = await referenceClient(ctx, clientName, true);
  if ("failure" in resolved) {
    return resolved.failure;
  }
  const client = resolved.ref;

  // The visit day: today unless they said otherwise ("kal gaya tha").
  let visitMs = DateTime.fromISO(ctx.nowIso, { zone: ctx.timezone }).toMillis();
  const whenPhrase = str(args.when_phrase);
  if (whenPhrase) {
    const when = resolveWhen({
      phrase: whenPhrase,
      timezone: ctx.timezone,
      nowIso: ctx.nowIso,
      tense: "past",
      period: periodOf(args.day_period),
      defaultHour: 12,
    });
    if (when.epochMs == null) {
      return fail("needs_date", `Could not read the visit date from "${whenPhrase}" — which day was it?`);
    }
    visitMs = when.epochMs;
  }
  const dateLabel = sheetDate(visitMs, ctx.timezone);

  // Where: what they said; the phone's fix only when they said they are at
  // the client.
  let location = str(args.location);
  const pin = args.at_client_location === true && ctx.coords ? { lat: ctx.coords.lat, lng: ctx.coords.lng } : null;
  if (!location && pin) {
    location =
      stripPlusCode(
        (await nearestPlaceLabel(pin).catch(() => null)) ??
          (await reverseGeocode(pin).catch(() => null)) ??
          "",
      );
  }

  const rawType = str(args.visit_type);
  const visitType = VISIT_TYPES.find((t) => t.toLowerCase() === rawType.toLowerCase()) ?? (rawType || "New");

  const data = {
    kind: "visit" as const,
    client,
    visitDateMs: visitMs,
    dateLabel,
    contactPerson: str(args.contact_person),
    contactPhone: str(args.contact_phone),
    location,
    lat: pin?.lat ?? null,
    lng: pin?.lng ?? null,
    visitType,
    products: str(args.products),
    discussion: str(args.discussion),
    status: str(args.status),
    nextStep: str(args.next_step),
    timezone: ctx.timezone,
  };

  const lines: DraftCardLine[] = [
    { label: "Date", value: dateLabel },
    { label: "Client", value: client.createNew ? `${client.name} (new client)` : client.name },
  ];
  const add = (label: string, value: string) => {
    if (value) lines.push({ label, value });
  };
  add("Met", [data.contactPerson, data.contactPhone].filter(Boolean).join(" · "));
  add("Location", data.location);
  if (pin) lines.push({ label: "Pin", value: `Current location saved as ${client.name}'s place` });
  add("Visit type", data.visitType);
  add("Products", data.products);
  add("Discussion", data.discussion);
  add("Status", data.status);
  add("Next step", data.nextStep);
  lines.push({
    label: "Saves to",
    value: ctx.googleToken ? "Aivy + DSR Google Sheet" : "Aivy (DSR sheet catches up when Google is connected)",
  });

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "visit",
    title: "Visit (DSR)",
    icon: "🧾",
    lines,
    chatId: ctx.chatId,
    data,
  });
  return draftResult(
    draft,
    "Visit card ready. Ask them to check it and confirm — nothing is saved yet. " +
      "After it is confirmed, ask whether to set a follow-up for this client.",
  );
}

// ---------------------------------------------------------------------------
// set_visit_followup
// ---------------------------------------------------------------------------

export async function setVisitFollowupTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const whenPhrase = str(args.when_phrase);
  if (!whenPhrase) {
    return fail("needs_date", "When should the follow-up be? (e.g. 10 din baad, agle Monday 11 baje)");
  }
  const visitId = str(args.visit_id);
  const visit = visitId ? await getVisit(ctx.uid, visitId) : await latestVisit(ctx.uid);
  if (!visit) {
    return fail("nothing_found", "No saved visit was found to attach this follow-up to — record the visit first.");
  }
  const when = resolveWhen({
    phrase: whenPhrase,
    timezone: ctx.timezone,
    nowIso: ctx.nowIso,
    tense: "future",
    period: periodOf(args.day_period),
    defaultHour: 11,
  });
  if (when.epochMs == null || when.epochMs <= Date.parse(ctx.nowIso)) {
    return fail("needs_date", `Could not read a future date from "${whenPhrase}" — when should it be?`);
  }
  const note = str(args.note) || visit.nextStep || visit.products || visit.discussion;

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "visit_followup",
    title: "Follow-up",
    icon: "🔔",
    lines: [
      { label: "Client", value: visit.clientName },
      { label: "When", value: when.label ?? whenPhrase },
      ...(note ? [{ label: "About", value: note }] : []),
      { label: "Visit", value: visit.dateLabel },
    ],
    chatId: ctx.chatId,
    data: {
      kind: "visit_followup",
      visitId: visit.id,
      clientName: visit.clientName,
      whenMs: when.epochMs,
      whenLabel: when.label ?? whenPhrase,
      note,
      timezone: ctx.timezone,
    },
  });
  return draftResult(draft, "Follow-up card ready — ask them to confirm. It sets a reminder and fills the DSR row's follow-up date.");
}

// ---------------------------------------------------------------------------
// list_visits
// ---------------------------------------------------------------------------

/** "today" | "yesterday" | "this_week" | "last_week" | "this_month" | "last_month" | "last_30_days". */
export function periodRange(period: string, nowIso: string, timezone: string): { fromMs: number; toMs: number; label: string } {
  const now = DateTime.fromISO(nowIso, { zone: timezone });
  const day = now.startOf("day");
  switch (period) {
    case "yesterday":
      return { fromMs: day.minus({ days: 1 }).toMillis(), toMs: day.toMillis(), label: "yesterday" };
    case "this_week":
      return { fromMs: now.startOf("week").toMillis(), toMs: day.plus({ days: 1 }).toMillis(), label: "this week" };
    case "last_week": {
      const start = now.startOf("week").minus({ weeks: 1 });
      return { fromMs: start.toMillis(), toMs: start.plus({ weeks: 1 }).toMillis(), label: "last week" };
    }
    case "this_month":
      return { fromMs: now.startOf("month").toMillis(), toMs: day.plus({ days: 1 }).toMillis(), label: now.toFormat("LLLL") };
    case "last_month": {
      const start = now.startOf("month").minus({ months: 1 });
      return { fromMs: start.toMillis(), toMs: start.plus({ months: 1 }).toMillis(), label: start.toFormat("LLLL") };
    }
    case "last_30_days":
      return { fromMs: day.minus({ days: 30 }).toMillis(), toMs: day.plus({ days: 1 }).toMillis(), label: "the last 30 days" };
    default:
      return { fromMs: day.toMillis(), toMs: day.plus({ days: 1 }).toMillis(), label: "today" };
  }
}

export async function listVisitsTool(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const period = str(args.period) || (str(args.client_name) ? "last_month" : "today");
  const range = periodRange(period, ctx.nowIso, ctx.timezone);
  const client = str(args.client_name).toLowerCase();
  // A client question looks further back than a day question.
  const fromMs = client && !str(args.period) ? range.fromMs - 365 * 24 * 3600 * 1000 : range.fromMs;
  const visits = await listVisits(ctx.uid, { fromMs, toMs: range.toMs, clientLower: client || undefined });
  const sheet = await dsrSheetLink(ctx.uid).catch(() => null);
  return dataResult({
    period: range.label,
    ...(client ? { client: str(args.client_name) } : {}),
    count: visits.length,
    visits: visits.map((v) => ({
      visit_id: v.id,
      date: v.dateLabel,
      client: v.clientName,
      met: v.contactPerson,
      location: v.location,
      type: v.visitType,
      products: v.products,
      discussion: v.discussion,
      status: v.status,
      next_step: v.nextStep,
      ...(v.followUpMs > 0 ? { follow_up: v.followUpLabel } : {}),
      in_sheet: v.sheetRow != null,
    })),
    ...(sheet ? { dsr_sheet_link: sheet } : {}),
  });
}

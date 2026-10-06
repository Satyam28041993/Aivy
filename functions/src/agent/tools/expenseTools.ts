/**
 * Travel expense for a day of visits.
 *
 * The flow the user asked for: on a day they recorded visits, Aivy asks at
 * 8 PM for the expense entry → they say where they started → Aivy routes
 * start → each visit of the day in order → back, on Google Maps, and shows
 * the kilometres leg by leg on one card → confirm writes the day to Aivy and
 * one row per leg to their expense sheet.
 */

import { DateTime } from "luxon";

import { createDraft } from "../draftStore";
import { resolveWhen } from "../dateResolve";
import { computeRoute, MapsApiError, resolvePlacePoint, type Coords } from "../google/maps";
import type { DraftCardLine } from "../draftTypes";
import { findSavedPlace } from "../placesStore";
import { dataResult, draftResult, fail, type ToolContext, type ToolResult } from "../toolTypes";
import { listVisits, sheetDate, type VisitRecord } from "../visitStore";
import {
  dayKey,
  expenseSettings,
  expenseSheetLink,
  getExpense,
  listExpenses,
  priceLegs,
} from "../expenseStore";
import { periodRange } from "./visitTools";

function str(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

/** A point on the day's route: what to show, and what to hand Maps. */
export interface RoutePoint {
  label: string;
  where: string | Coords;
  purpose: string;
}

/** Where a visit was, for routing: its pin if the phone gave one, else its words. */
export function visitPoint(v: VisitRecord): RoutePoint {
  const label = v.location ? `${v.clientName} (${v.location})` : v.clientName;
  const where: string | Coords =
    v.lat != null && v.lng != null
      ? { lat: v.lat, lng: v.lng }
      : v.location
        ? `${v.clientName}, ${v.location}`
        : v.clientName;
  return { label, where, purpose: v.clientName };
}

/** "Home", "ghar", or a saved place name → its pin; anything else → Places, near them. */
async function resolveStart(ctx: ToolContext, text: string): Promise<RoutePoint> {
  const saved = await findSavedPlace(ctx.uid, text).catch(() => null);
  if (saved) {
    return { label: saved.name, where: { lat: saved.lat, lng: saved.lng }, purpose: "Start" };
  }
  const place = await resolvePlacePoint({ query: text, coords: ctx.coords ?? null, near: ctx.userCity ?? null });
  if (place?.coords) {
    return { label: text, where: place.coords, purpose: "Start" };
  }
  return { label: text, where: text, purpose: "Start" };
}

function samePlace(a: string | Coords, b: string | Coords): boolean {
  if (typeof a === "string" || typeof b === "string") {
    return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
  }
  return Math.abs(a.lat - b.lat) < 0.0005 && Math.abs(a.lng - b.lng) < 0.0005;
}

/** Road km between two points, by two-wheeler, falling back to car routing. */
async function legKm(from: RoutePoint, to: RoutePoint): Promise<number | null> {
  if (samePlace(from.where, to.where)) return 0;
  const bike = await computeRoute({ origin: from.where, destination: to.where, mode: "TWO_WHEELER" }).catch(
    (e) => {
      if (e instanceof MapsApiError) return null;
      throw e;
    },
  );
  if (bike) return bike.distanceKm;
  const car = await computeRoute({ origin: from.where, destination: to.where, mode: "DRIVE" });
  return car ? car.distanceKm : null;
}

// ---------------------------------------------------------------------------
// record_travel_expense
// ---------------------------------------------------------------------------

export async function recordTravelExpenseTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const startText = str(args.start_point);
  if (!startText) {
    return fail("needs_detail", "Where did they start from today? (home, office, or an area)");
  }

  let dayMs = DateTime.fromISO(ctx.nowIso, { zone: ctx.timezone }).toMillis();
  const whenPhrase = str(args.when_phrase);
  if (whenPhrase) {
    const when = resolveWhen({
      phrase: whenPhrase,
      timezone: ctx.timezone,
      nowIso: ctx.nowIso,
      tense: "past",
      period: null,
      defaultHour: 12,
    });
    if (when.epochMs == null) {
      return fail("needs_date", `Could not read the day from "${whenPhrase}" — which day's travel is it?`);
    }
    dayMs = when.epochMs;
  }
  const day = DateTime.fromMillis(dayMs, { zone: ctx.timezone }).startOf("day");
  const key = dayKey(day.toMillis(), ctx.timezone);
  const dateLabel = sheetDate(day.toMillis(), ctx.timezone);

  const already = await getExpense(ctx.uid, key);
  if (already) {
    return fail(
      "nothing_found",
      `Travel for ${dateLabel} is already recorded: ${already.totalKm} km, ₹${already.totalAmount}. ` +
        "Tell them it is already in; to change it, it has to be deleted first.",
    );
  }

  // The stops: what they listed, else the day's visits in the order made.
  const listed = Array.isArray(args.stops) ? args.stops.map(str).filter(Boolean) : [];
  let stops: RoutePoint[];
  if (listed.length > 0) {
    stops = listed.map((s) => ({ label: s, where: s, purpose: s }));
  } else {
    const visits = await listVisits(ctx.uid, {
      fromMs: day.toMillis(),
      toMs: day.plus({ days: 1 }).toMillis(),
    });
    visits.sort((a, b) => a.visitDateMs - b.visitDateMs || a.createdAtMs - b.createdAtMs);
    stops = visits.map(visitPoint);
  }
  if (stops.length === 0) {
    return fail(
      "nothing_found",
      `No visits are recorded for ${dateLabel}. Ask them to record the visits first, or to name the places they went (stops).`,
    );
  }

  const start = await resolveStart(ctx, startText);
  const endText = str(args.end_point);
  const end = endText && endText.toLowerCase() !== startText.toLowerCase() ? await resolveStart(ctx, endText) : start;
  const route = [start, ...stops, { ...end, purpose: "Return" }];

  const { ratePerKm, vehicle } = await expenseSettings(ctx.uid);
  const raw: Array<{ from: string; to: string; purpose: string; km: number }> = [];
  try {
    for (let i = 1; i < route.length; i++) {
      const from = route[i - 1]!;
      const to = route[i]!;
      const km = await legKm(from, to);
      if (km == null) {
        return fail("nothing_found", `Google Maps found no road from "${from.label}" to "${to.label}". Ask where exactly that is.`);
      }
      raw.push({ from: from.label, to: to.label, purpose: to.purpose, km });
    }
  } catch (e) {
    if (e instanceof MapsApiError) {
      return fail("nothing_found", `Google Maps could not measure the route just now (${e.message}).`);
    }
    throw e;
  }
  const priced = priceLegs(raw, ratePerKm);

  const lines: DraftCardLine[] = [{ label: "Date", value: dateLabel }];
  priced.legs.forEach((l, i) => {
    lines.push({ label: `${i + 1}. ${l.from} → ${l.to}`, value: `${l.km} km · ₹${l.amount}` });
  });
  lines.push({ label: "Total", value: `${priced.totalKm} km × ₹${ratePerKm} (${vehicle}) = ₹${priced.totalAmount}` });
  lines.push({
    label: "Saves to",
    value: ctx.googleToken ? "Aivy + Expense Google Sheet" : "Aivy (expense sheet catches up when Google is connected)",
  });

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "travel_expense",
    title: "Travel expense",
    icon: "🛵",
    lines,
    chatId: ctx.chatId,
    data: {
      kind: "travel_expense",
      day: key,
      dateMs: day.toMillis(),
      dateLabel,
      startPoint: start.label,
      endPoint: end.label,
      vehicle,
      ratePerKm,
      legs: priced.legs,
      totalKm: priced.totalKm,
      totalAmount: priced.totalAmount,
      timezone: ctx.timezone,
    },
  });
  return draftResult(
    draft,
    `Expense card ready: ${priced.totalKm} km, ₹${priced.totalAmount}. Tell them the total in one line and ask them to check the legs and confirm — nothing is saved yet. ` +
      "If a leg looks wrong, they can name the place more exactly and you call again.",
  );
}

// ---------------------------------------------------------------------------
// list_travel_expenses
// ---------------------------------------------------------------------------

export async function listTravelExpensesTool(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const range = periodRange(str(args.period) || "this_month", ctx.nowIso, ctx.timezone);
  const days = await listExpenses(ctx.uid, range);
  const sheet = await expenseSheetLink(ctx.uid).catch(() => null);
  return dataResult({
    period: range.label,
    days: days.length,
    total_km: Math.round(days.reduce((a, d) => a + d.totalKm, 0) * 10) / 10,
    total_amount: Math.round(days.reduce((a, d) => a + d.totalAmount, 0) * 100) / 100,
    entries: days.map((d) => ({
      date: d.dateLabel,
      start: d.startPoint,
      km: d.totalKm,
      amount: d.totalAmount,
      legs: d.legs.map((l) => `${l.from} → ${l.to}: ${l.km} km`),
    })),
    ...(sheet ? { expense_sheet_link: sheet } : {}),
  });
}

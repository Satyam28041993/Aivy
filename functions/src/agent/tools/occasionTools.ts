/**
 * Occasions — the dates that come back every year.
 *
 * Saving one is not a draft. A birthday is a fact the user is stating, not an
 * action with consequences: nothing leaves the building, nothing is spent, and
 * a wrong date is corrected by saying it again. Making them confirm a card for
 * "Ruchi's birthday is 19 October" would be ceremony for its own sake.
 */

import {
  daysUntil,
  deleteOccasion,
  findOccasion,
  isValidDayMonth,
  LEAD_DAYS,
  listOccasions,
  milestoneLabel,
  nextOccurrence,
  saveOccasion,
  type OccasionKind,
} from "../occasionStore";
import { dataResult, fail, type ToolContext, type ToolResult } from "../toolTypes";

function str(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

function num(raw: unknown): number {
  const n = Number(raw);
  return Number.isFinite(n) ? Math.trunc(n) : 0;
}

function kindOf(raw: unknown): OccasionKind {
  const k = str(raw).toLowerCase();
  if (k === "anniversary") {
    return "anniversary";
  }
  if (k === "birthday") {
    return "birthday";
  }
  return "other";
}

export async function saveOccasionTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const name = str(args.name);
  if (!name) {
    return fail("needs_detail", "Whose day is it?");
  }
  const day = num(args.day);
  const month = num(args.month);
  if (!isValidDayMonth(day, month)) {
    return fail("needs_date", "That date does not look right — which day and month?");
  }

  const saved = await saveOccasion(ctx.uid, {
    name,
    kind: kindOf(args.kind),
    day,
    month,
    year: num(args.year) || null,
  });

  const milestone = milestoneLabel(saved, ctx.timezone);
  return dataResult({
    saved: saved.name,
    kind: saved.kind,
    next: nextOccurrence(saved, ctx.timezone).toFormat("cccc, d LLLL yyyy"),
    days_away: daysUntil(saved, ctx.timezone),
    ...(milestone ? { milestone } : {}),
    // Said back, so the user knows this is not a one-off note.
    reminders_at: LEAD_DAYS.map((d) => (d === 0 ? "on the day" : `${d} days before`)),
  });
}

export async function listOccasionsTool(ctx: ToolContext): Promise<ToolResult> {
  const rows = await listOccasions(ctx.uid);
  if (rows.length === 0) {
    return fail("nothing_found", "No birthdays or anniversaries saved yet.");
  }
  const withDays = rows
    .map((o) => ({ o, days: daysUntil(o, ctx.timezone) }))
    .sort((a, b) => a.days - b.days);

  return dataResult({
    count: withDays.length,
    // Soonest first, because "what is coming up" is the question behind this.
    occasions: withDays.map(({ o, days }) => {
      const milestone = milestoneLabel(o, ctx.timezone);
      return {
        name: o.name,
        kind: o.kind,
        date: nextOccurrence(o, ctx.timezone).toFormat("d LLLL"),
        days_away: days,
        ...(milestone ? { milestone } : {}),
      };
    }),
  });
}

export async function forgetOccasionTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const name = str(args.name);
  if (!name) {
    return fail("needs_detail", "Which one should I remove?");
  }
  const existing = await findOccasion(ctx.uid, name);
  if (!existing) {
    return fail("nothing_found", `Nothing saved for "${name}".`);
  }
  await deleteOccasion(ctx.uid, name);
  return dataResult({ removed: existing.name });
}

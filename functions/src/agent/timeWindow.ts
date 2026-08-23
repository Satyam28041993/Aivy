/**
 * Named time windows the read tools accept.
 *
 * Kept separate from the Firestore reads so the arithmetic is testable on its
 * own — "is week" meaning Monday-to-Sunday rather than a rolling seven days is
 * the sort of thing that is easy to get wrong and hard to notice in a report.
 */

import { DateTime } from "luxon";

export type WindowName =
  | "today"
  | "tomorrow"
  | "yesterday"
  | "this_week"
  | "last_week"
  | "next_week"
  | "this_month"
  | "last_month"
  | "overdue"
  | "all";

export interface TimeWindow {
  startMs: number;
  endMs: number;
  label: string;
  name: WindowName;
}

const ALL_WINDOWS: ReadonlySet<string> = new Set<WindowName>([
  "today",
  "tomorrow",
  "yesterday",
  "this_week",
  "last_week",
  "next_week",
  "this_month",
  "last_month",
  "overdue",
  "all",
]);

export function isWindowName(raw: unknown): raw is WindowName {
  return typeof raw === "string" && ALL_WINDOWS.has(raw);
}

/** Resolves a window name against "now" in the user's zone. */
export function resolveWindow(
  name: WindowName,
  timezone: string,
  nowIso?: string,
): TimeWindow {
  const zone = timezone || "Asia/Kolkata";
  const now = nowIso
    ? DateTime.fromISO(nowIso, { zone })
    : DateTime.now().setZone(zone);
  const base = now.isValid ? now : DateTime.now().setZone(zone);

  const dayStart = base.startOf("day");

  switch (name) {
    case "today":
      return {
        startMs: dayStart.toMillis(),
        endMs: dayStart.endOf("day").toMillis(),
        label: "aaj",
        name,
      };
    case "tomorrow": {
      const d = dayStart.plus({ days: 1 });
      return { startMs: d.toMillis(), endMs: d.endOf("day").toMillis(), label: "kal", name };
    }
    case "yesterday": {
      const d = dayStart.minus({ days: 1 });
      return { startMs: d.toMillis(), endMs: d.endOf("day").toMillis(), label: "kal (beeta)", name };
    }
    case "this_week":
      return {
        startMs: base.startOf("week").toMillis(),
        endMs: base.endOf("week").toMillis(),
        label: "is hafte",
        name,
      };
    case "last_week": {
      const d = base.minus({ weeks: 1 });
      return {
        startMs: d.startOf("week").toMillis(),
        endMs: d.endOf("week").toMillis(),
        label: "pichhle hafte",
        name,
      };
    }
    case "next_week": {
      const d = base.plus({ weeks: 1 });
      return {
        startMs: d.startOf("week").toMillis(),
        endMs: d.endOf("week").toMillis(),
        label: "agle hafte",
        name,
      };
    }
    case "this_month":
      return {
        startMs: base.startOf("month").toMillis(),
        endMs: base.endOf("month").toMillis(),
        label: "is mahine",
        name,
      };
    case "last_month": {
      const d = base.minus({ months: 1 });
      return {
        startMs: d.startOf("month").toMillis(),
        endMs: d.endOf("month").toMillis(),
        label: "pichhle mahine",
        name,
      };
    }
    case "overdue":
      // Everything already past, up to the end of yesterday.
      return {
        startMs: 0,
        endMs: dayStart.toMillis() - 1,
        label: "overdue",
        name,
      };
    case "all":
    default:
      return {
        startMs: 0,
        endMs: Number.MAX_SAFE_INTEGER,
        label: "abhi tak",
        name: "all",
      };
  }
}

/** Short day label for list rows, e.g. "aaj 4:00 PM" / "26 Aug 11:00 AM". */
export function rowTimeLabel(ms: number, timezone: string, nowIso?: string): string {
  const zone = timezone || "Asia/Kolkata";
  const now = nowIso ? DateTime.fromISO(nowIso, { zone }) : DateTime.now().setZone(zone);
  const base = now.isValid ? now : DateTime.now().setZone(zone);
  const dt = DateTime.fromMillis(ms, { zone });
  const days = dt.startOf("day").diff(base.startOf("day"), "days").days;
  const time = dt.toFormat("h:mm a");
  if (days === 0) return `aaj ${time}`;
  if (days === 1) return `kal ${time}`;
  if (days === -1) return `kal (beeta) ${time}`;
  return `${dt.toFormat("d MMM")} ${time}`;
}

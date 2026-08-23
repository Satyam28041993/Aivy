import { describe, expect, it } from "vitest";
import { DateTime } from "luxon";

import { isWindowName, resolveWindow, rowTimeLabel } from "./timeWindow";

const ZONE = "Asia/Kolkata";
// Saturday 23 August 2025, 14:30 IST.
const NOW = "2025-08-23T14:30:00+05:30";

function span(name: Parameters<typeof resolveWindow>[0]) {
  const w = resolveWindow(name, ZONE, NOW);
  return {
    start: DateTime.fromMillis(w.startMs, { zone: ZONE }),
    end: DateTime.fromMillis(w.endMs, { zone: ZONE }),
    label: w.label,
  };
}

describe("isWindowName", () => {
  it("accepts the known names and rejects anything else", () => {
    expect(isWindowName("this_week")).toBe(true);
    expect(isWindowName("overdue")).toBe(true);
    expect(isWindowName("someday")).toBe(false);
    expect(isWindowName(7)).toBe(false);
    expect(isWindowName(null)).toBe(false);
  });
});

describe("day windows", () => {
  it("covers today from midnight to midnight", () => {
    const { start, end } = span("today");
    expect(start.day).toBe(23);
    expect(start.hour).toBe(0);
    expect(end.day).toBe(23);
    expect(end.hour).toBe(23);
  });

  it("covers tomorrow and yesterday", () => {
    expect(span("tomorrow").start.day).toBe(24);
    expect(span("yesterday").start.day).toBe(22);
  });
});

describe("week windows", () => {
  it("treats this week as Monday to Sunday, not a rolling seven days", () => {
    const { start, end } = span("this_week");
    // Saturday 23 Aug sits in the Mon 18 – Sun 24 week.
    expect(start.day).toBe(18);
    expect(start.weekday).toBe(1);
    expect(end.day).toBe(24);
    expect(end.weekday).toBe(7);
  });

  it("shifts a whole week back and forward", () => {
    expect(span("last_week").start.day).toBe(11);
    expect(span("last_week").end.day).toBe(17);
    expect(span("next_week").start.day).toBe(25);
    expect(span("next_week").end.day).toBe(31);
  });
});

describe("month windows", () => {
  it("covers the calendar month", () => {
    const { start, end } = span("this_month");
    expect(start.day).toBe(1);
    expect(start.month).toBe(8);
    expect(end.day).toBe(31);
  });

  it("covers the previous calendar month", () => {
    const { start, end } = span("last_month");
    expect(start.month).toBe(7);
    expect(start.day).toBe(1);
    expect(end.day).toBe(31);
  });
});

describe("overdue and all", () => {
  it("ends overdue just before today starts", () => {
    const w = resolveWindow("overdue", ZONE, NOW);
    const todayStart = resolveWindow("today", ZONE, NOW).startMs;
    expect(w.startMs).toBe(0);
    expect(w.endMs).toBe(todayStart - 1);
  });

  it("makes 'all' unbounded", () => {
    const w = resolveWindow("all", ZONE, NOW);
    expect(w.startMs).toBe(0);
    expect(w.endMs).toBe(Number.MAX_SAFE_INTEGER);
  });

  it("falls back to 'all' for an unknown name", () => {
    const w = resolveWindow("nonsense" as never, ZONE, NOW);
    expect(w.name).toBe("all");
  });
});

describe("rowTimeLabel", () => {
  const at = (iso: string) => DateTime.fromISO(iso, { zone: ZONE }).toMillis();

  it("says aaj / kal for nearby days", () => {
    expect(rowTimeLabel(at("2025-08-23T16:00:00+05:30"), ZONE, NOW)).toBe("aaj 4:00 PM");
    expect(rowTimeLabel(at("2025-08-24T11:00:00+05:30"), ZONE, NOW)).toBe("kal 11:00 AM");
    expect(rowTimeLabel(at("2025-08-22T09:30:00+05:30"), ZONE, NOW)).toBe("kal (beeta) 9:30 AM");
  });

  it("spells out the date further away", () => {
    expect(rowTimeLabel(at("2025-08-30T18:00:00+05:30"), ZONE, NOW)).toBe("30 Aug 6:00 PM");
  });
});

import { describe, expect, it } from "vitest";
import { DateTime } from "luxon";

import {
  daysUntil,
  isValidDayMonth,
  milestoneLabel,
  nextOccurrence,
  type Occasion,
} from "./occasionStore";

const ZONE = "Asia/Kolkata";

function at(iso: string): number {
  return DateTime.fromISO(iso, { zone: ZONE }).toMillis();
}

function occasion(part: Partial<Occasion>): Occasion {
  return {
    id: "o1",
    name: "Ruchi",
    nameKey: "ruchi",
    kind: "birthday",
    day: 19,
    month: 10,
    year: 1995,
    createdAtMs: 0,
    ...part,
  };
}

describe("nextOccurrence", () => {
  it("stays in this year when the date is still ahead", () => {
    const next = nextOccurrence({ day: 19, month: 10 }, ZONE, at("2026-08-30T16:00"));
    expect(next.toISODate()).toBe("2026-10-19");
  });

  it("rolls into next year once the date has passed", () => {
    const next = nextOccurrence({ day: 19, month: 10 }, ZONE, at("2026-11-01T09:00"));
    expect(next.toISODate()).toBe("2027-10-19");
  });

  it("counts the day itself as today, not a year away", () => {
    // Late on the day of, a birthday has not moved to next year.
    const next = nextOccurrence({ day: 19, month: 10 }, ZONE, at("2026-10-19T23:30"));
    expect(next.toISODate()).toBe("2026-10-19");
  });

  it("puts a 29 February date on 1 March in a common year", () => {
    const next = nextOccurrence({ day: 29, month: 2 }, ZONE, at("2027-01-10T09:00"));
    expect(next.toISODate()).toBe("2027-03-01");
  });
});

describe("daysUntil", () => {
  it("is the number the reminder leads are matched against", () => {
    expect(daysUntil({ day: 19, month: 10 }, ZONE, at("2026-10-04T09:00"))).toBe(15);
    expect(daysUntil({ day: 19, month: 10 }, ZONE, at("2026-10-09T09:00"))).toBe(10);
    expect(daysUntil({ day: 19, month: 10 }, ZONE, at("2026-10-14T09:00"))).toBe(5);
    expect(daysUntil({ day: 19, month: 10 }, ZONE, at("2026-10-18T09:00"))).toBe(1);
    expect(daysUntil({ day: 19, month: 10 }, ZONE, at("2026-10-19T09:00"))).toBe(0);
  });

  it("does not drift with the time of day", () => {
    // A check at 03:30 UTC is 09:00 in Kolkata; both must give the same lead.
    expect(daysUntil({ day: 19, month: 10 }, ZONE, at("2026-10-04T00:05"))).toBe(15);
    expect(daysUntil({ day: 19, month: 10 }, ZONE, at("2026-10-04T23:55"))).toBe(15);
  });
});

describe("milestoneLabel", () => {
  it("counts the birthday they are about to have, not the last one", () => {
    expect(milestoneLabel(occasion({}), ZONE, at("2026-08-30T09:00"))).toBe("turning 31");
  });

  it("says years for an anniversary, counting the one coming up", () => {
    // 21 May is behind us on 30 August, so the next one is 2027 — their tenth,
    // not the ninth they have already had.
    expect(
      milestoneLabel(
        occasion({ kind: "anniversary", day: 21, month: 5, year: 2017 }),
        ZONE,
        at("2026-08-30T09:00"),
      ),
    ).toBe("10 years");
  });

  it("says nothing when the original year is unknown", () => {
    expect(milestoneLabel(occasion({ year: 0 }), ZONE, at("2026-08-30T09:00"))).toBe("");
  });
});

describe("isValidDayMonth", () => {
  it("accepts real dates including 29 February", () => {
    expect(isValidDayMonth(19, 10)).toBe(true);
    expect(isValidDayMonth(29, 2)).toBe(true);
  });

  it("rejects a date that cannot exist", () => {
    expect(isValidDayMonth(31, 4)).toBe(false);
    expect(isValidDayMonth(30, 2)).toBe(false);
    expect(isValidDayMonth(0, 5)).toBe(false);
    expect(isValidDayMonth(12, 13)).toBe(false);
  });
});

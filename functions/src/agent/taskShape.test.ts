/**
 * The two pieces of task behaviour with a right and a wrong answer.
 *
 * `kindOf` and friends decide whether every project written before tasks
 * existed still reads as a project — get that wrong and a year of work
 * disappears from one list and floods another. `nudgeFor` decides when the
 * halfway check-in lands, and its whole job is to never land somewhere absurd:
 * three in the morning, or two hours before the thing is due anyway.
 */

import { describe, expect, it } from "vitest";

import { areaOf, dueOf, isLive, kindOf, type Project } from "./projectStore";
import { nudgeFor } from "./tools/projectTools";

const ZONE = "Asia/Kolkata";
const HOUR = 60 * 60 * 1000;

function project(part: Partial<Project>): Project {
  return {
    id: "p1",
    name: "Something",
    nameKey: "something",
    clientName: "",
    status: "active",
    note: "",
    createdAtMs: 0,
    updatedAtMs: 0,
    ...part,
  };
}

describe("reading docs written before tasks existed", () => {
  it("treats a doc with no kind as a project", () => {
    // There is no migration. Every project already in Firestore arrives here
    // without these three fields, and all of them are projects.
    const old = project({});
    expect(kindOf(old)).toBe("project");
    expect(areaOf(old)).toBe("work");
    expect(dueOf(old)).toBe(0);
  });

  it("reads the new fields when they are there", () => {
    const t = project({ kind: "task", area: "personal", dueMs: 1_700_000_000_000 });
    expect(kindOf(t)).toBe("task");
    expect(areaOf(t)).toBe("personal");
    expect(dueOf(t)).toBe(1_700_000_000_000);
  });

  it("does not treat a rubbish dueMs as a deadline", () => {
    expect(dueOf(project({ dueMs: -5 }))).toBe(0);
    expect(dueOf(project({ dueMs: Number.NaN }))).toBe(0);
  });

  it("counts on_hold as still live, and closed as not", () => {
    expect(isLive(project({ status: "on_hold" }))).toBe(true);
    expect(isLive(project({ status: "done" }))).toBe(false);
    expect(isLive(project({ status: "won" }))).toBe(false);
  });
});

describe("nudgeFor", () => {
  const now = Date.parse("2026-09-01T10:00:00+05:30");

  it("lands halfway to a deadline several days out", () => {
    const due = Date.parse("2026-09-05T18:00:00+05:30");
    const ms = nudgeFor(now, due, ZONE);
    expect(ms).toBeGreaterThan(now);
    expect(ms).toBeLessThan(due);
    // Roughly the middle, not the ends.
    expect(Math.abs(ms - (now + (due - now) / 2))).toBeLessThan(12 * HOUR);
  });

  it("gives nothing for work due inside a day", () => {
    // Two alarms for something due tomorrow morning is nagging, not help.
    expect(nudgeFor(now, now + 20 * HOUR, ZONE)).toBe(0);
  });

  it("gives nothing when there is no deadline at all", () => {
    expect(nudgeFor(now, 0, ZONE)).toBe(0);
  });

  it("never lands in the middle of the night", () => {
    // Midpoint here falls at about 4am, which is the one time a nudge is worse
    // than no nudge.
    const due = Date.parse("2026-09-03T22:00:00+05:30");
    const ms = nudgeFor(now, due, ZONE);
    expect(ms).toBeGreaterThan(0);
    const hour = Number(
      new Intl.DateTimeFormat("en-GB", {
        hour: "2-digit",
        hour12: false,
        timeZone: ZONE,
      }).format(new Date(ms)),
    );
    expect(hour).toBeGreaterThanOrEqual(9);
    expect(hour).toBeLessThan(21);
  });

  it("drops the nudge rather than crowding the deadline", () => {
    // Moving it to a civil hour must never push it up against the deadline —
    // better one alarm than two an hour apart.
    for (let h = 30; h < 96; h += 1) {
      const due = now + h * HOUR;
      const ms = nudgeFor(now, due, ZONE);
      if (ms > 0) {
        expect(ms).toBeLessThan(due - 2 * HOUR);
        expect(ms).toBeGreaterThan(now + HOUR);
      }
    }
  });
});

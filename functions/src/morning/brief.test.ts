import { describe, expect, it } from "vitest";

import { dateKeyFor } from "./brief";

/**
 * The cache key decides whether a morning is rebuilt or handed back, so it has
 * to turn over at local midnight — not at UTC midnight, which in India is half
 * past five in the morning and would rebuild the brief while someone reads it.
 */
describe("dateKeyFor", () => {
  const IST = "Asia/Kolkata";

  it("is the local date, not the UTC one", () => {
    // 30 Aug 20:00 UTC is already 31 Aug in Kolkata.
    const ms = Date.parse("2026-08-30T20:00:00Z");
    expect(dateKeyFor(IST, ms)).toBe("2026-08-31");
    expect(dateKeyFor("UTC", ms)).toBe("2026-08-30");
  });

  it("holds steady across a working day", () => {
    const morning = Date.parse("2026-08-30T03:30:00Z");
    const evening = Date.parse("2026-08-30T16:00:00Z");
    expect(dateKeyFor(IST, morning)).toBe(dateKeyFor(IST, evening));
  });

  it("turns over at local midnight", () => {
    const before = Date.parse("2026-08-30T18:25:00Z");
    const after = Date.parse("2026-08-30T18:35:00Z");
    expect(dateKeyFor(IST, before)).toBe("2026-08-30");
    expect(dateKeyFor(IST, after)).toBe("2026-08-31");
  });

  it("falls back rather than throwing on an empty zone", () => {
    expect(dateKeyFor("", Date.parse("2026-08-30T20:00:00Z"))).toBe("2026-08-31");
  });
});

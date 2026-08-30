import { describe, expect, it } from "vitest";

import { dateKeyFor, parseBrief } from "./brief";

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

/**
 * The parser threw away every Google Alert entry for two days.
 *
 * The instruction asked for the term in "group" and the explanation under it;
 * the model put that explanation in "detail" and left "headline" empty, which
 * was reasonable — and the parser dropped any item without a headline. The
 * section then arrived empty and the screen said "Nothing new", which is
 * indistinguishable from having no alerts at all.
 */
describe("parseBrief", () => {
  function alerts(items: unknown[]): string {
    return JSON.stringify({
      greeting: "Good evening",
      sections: [{ kind: "alerts", title: "Google Alerts", items }],
    });
  }

  it("keeps an entry whose words are all in detail", () => {
    const out = parseBrief(alerts([{ group: "Canva ai", detail: "Canva ki valuation giri." }]));
    expect(out!.sections[0]!.items).toEqual([
      { headline: "Canva ki valuation giri.", detail: undefined, group: "Canva ai", link: undefined },
    ]);
  });

  it("keeps both when both are given", () => {
    const out = parseBrief(
      alerts([{ group: "AI", headline: "Naye model aaye.", detail: "Sasta reasoning." }]),
    );
    expect(out!.sections[0]!.items[0]).toMatchObject({
      headline: "Naye model aaye.",
      detail: "Sasta reasoning.",
      group: "AI",
    });
  });

  it("still drops an entry that says nothing at all", () => {
    const out = parseBrief(alerts([{ group: "Marketing" }, { headline: "  " }]));
    expect(out!.sections[0]!.items).toEqual([]);
  });

  it("reads through a code fence rather than losing the whole brief", () => {
    const out = parseBrief('```json\n' + alerts([{ detail: "kuch hua." }]) + '\n```');
    expect(out!.sections[0]!.items[0]!.headline).toBe("kuch hua.");
  });

  it("returns null on something that is not JSON at all", () => {
    expect(parseBrief("sorry, I cannot help with that")).toBeNull();
  });
});

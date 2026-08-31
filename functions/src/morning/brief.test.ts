import { describe, expect, it } from "vitest";

import { dateKeyFor, dueWords, orderSections, parseBrief, summaryLine } from "./brief";

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

/**
 * The one line of the brief a person acts on before reading anything else.
 *
 * Lateness is counted in whole local days, not in elapsed hours: something due
 * at nine last night is a day late this morning, and calling it "11 hours late"
 * is both true and useless.
 */
describe("dueWords", () => {
  const IST = "Asia/Kolkata";
  const now = Date.parse("2026-09-10T08:00:00+05:30");

  it("calls today today, and tomorrow tomorrow", () => {
    expect(dueWords(Date.parse("2026-09-10T18:00:00+05:30"), IST, now)).toEqual({
      text: "due today",
      tone: "due",
    });
    expect(dueWords(Date.parse("2026-09-11T09:00:00+05:30"), IST, now)).toEqual({
      text: "due tomorrow",
      tone: "due",
    });
  });

  it("counts lateness in days, and marks it", () => {
    // Due last night at nine: a day late this morning, not eleven hours.
    expect(dueWords(Date.parse("2026-09-09T21:00:00+05:30"), IST, now)).toEqual({
      text: "1 day late",
      tone: "late",
    });
    expect(dueWords(Date.parse("2026-09-07T10:00:00+05:30"), IST, now)).toEqual({
      text: "3 days late",
      tone: "late",
    });
  });

  it("gives a plain date further out, with no colour", () => {
    const out = dueWords(Date.parse("2026-09-18T10:00:00+05:30"), IST, now);
    expect(out.text).toBe("due 18 Sep");
    expect(out.tone).toBeUndefined();
  });

  it("says so when there is no date, rather than inventing one", () => {
    expect(dueWords(0, IST, now)).toEqual({ text: "no date" });
  });
});

function section(kind: string, items: Array<Record<string, unknown>> = []) {
  return {
    kind,
    title: kind,
    items: items as never,
  };
}

/**
 * The order a morning is used in.
 *
 * Mail, news and alerts came first because that is the order they were
 * gathered in, which put the one thing owed to a director below twenty lines
 * of alert digest.
 */
describe("orderSections", () => {
  it("puts what is owed above what is merely worth reading", () => {
    const out = orderSections([
      section("mail"),
      section("news"),
      section("alerts"),
      section("today"),
      section("tasks"),
      section("projects"),
    ]);
    expect(out.map((s) => s.kind)).toEqual([
      "tasks",
      "projects",
      "today",
      "mail",
      "news",
      "alerts",
    ]);
  });

  it("keeps a section nobody planned for rather than dropping it", () => {
    const out = orderSections([section("weather"), section("tasks")]);
    expect(out.map((s) => s.kind)).toEqual(["tasks", "weather"]);
  });
});

describe("summaryLine", () => {
  it("counts what is owed before anything is read", () => {
    const line = summaryLine([
      section("tasks", [
        { headline: "PPT", tone: "late" },
        { headline: "Movie", tone: "due" },
        { headline: "Later thing" },
      ]),
      section("mail", [{ headline: "A reply is waiting" }]),
      section("alerts", [
        { headline: "x", group: "Canva" },
        { headline: "y", group: "Canva" },
        { headline: "z", group: "Labels" },
      ]),
    ]);
    // Two alert mails under one term are one topic, not two.
    expect(line).toBe("1 late  ·  1 due today  ·  1 mail  ·  2 alert topics");
  });

  it("says so plainly when nothing is owed", () => {
    expect(summaryLine([section("tasks"), section("mail")])).toBe("Nothing owed today.");
  });
});

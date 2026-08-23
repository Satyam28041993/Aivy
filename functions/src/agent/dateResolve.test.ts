import { describe, expect, it } from "vitest";
import { DateTime } from "luxon";

import { disambiguateHour, resolveWhen } from "./dateResolve";
import { normalizeName, capitalizeWords } from "./nameNormalize";

const ZONE = "Asia/Kolkata";
// Saturday 23 August 2025, 14:30 IST. Weekday = 6.
const NOW = "2025-08-23T14:30:00+05:30";

function resolve(phrase: string, opts: Partial<Parameters<typeof resolveWhen>[0]> = {}) {
  return resolveWhen({ phrase, timezone: ZONE, nowIso: NOW, ...opts });
}

function local(iso: string | null): DateTime | null {
  return iso ? DateTime.fromISO(iso, { zone: ZONE }) : null;
}

describe("disambiguateHour — bug #1: no blanket +12", () => {
  it("reads 8-11 as morning hours when no period is given", () => {
    expect(disambiguateHour(8, null)).toBe(8);
    expect(disambiguateHour(9, null)).toBe(9);
    expect(disambiguateHour(10, null)).toBe(10);
    expect(disambiguateHour(11, null)).toBe(11);
  });

  it("reads 1-7 as evening hours when no period is given", () => {
    expect(disambiguateHour(1, null)).toBe(13);
    expect(disambiguateHour(4, null)).toBe(16);
    expect(disambiguateHour(6, null)).toBe(18);
    expect(disambiguateHour(7, null)).toBe(19);
  });

  it("lets an explicit period override the default split", () => {
    expect(disambiguateHour(4, "morning")).toBe(4);
    expect(disambiguateHour(11, "night")).toBe(23);
    expect(disambiguateHour(9, "evening")).toBe(21);
  });

  it("handles 12 and already-24h values", () => {
    expect(disambiguateHour(12, null)).toBe(12);
    expect(disambiguateHour(12, "morning")).toBe(0);
    expect(disambiguateHour(15, null)).toBe(15);
    expect(disambiguateHour(0, null)).toBe(0);
  });
});

describe("bug #1 — 'kal 11 baje' must be 11 AM, not 11 PM", () => {
  it("resolves the exact phrase from the user's own example", () => {
    const r = resolve("kal 11 baje");
    const dt = local(r.iso)!;
    expect(dt.hour).toBe(11);
    expect(dt.day).toBe(24);
    expect(r.label).toBe("Ravivar, 24 August, 11:00 AM");
  });

  it("still reads 'kal 6 baje' as the evening", () => {
    const dt = local(resolve("kal 6 baje").iso)!;
    expect(dt.hour).toBe(18);
  });

  it("reads 'kal 4 baje' as the evening", () => {
    expect(local(resolve("kal 4 baje").iso)!.hour).toBe(16);
  });

  it("honours 'shaam' against the morning default", () => {
    expect(local(resolve("kal shaam 9 baje").iso)!.hour).toBe(21);
  });
});

describe("bug #2 — 'kal 10' and 'kal 10 baje' must agree", () => {
  it("resolves both to the same hour", () => {
    const bare = local(resolve("kal 10").iso)!;
    const withBaje = local(resolve("kal 10 baje").iso)!;
    expect(bare.hour).toBe(withBaje.hour);
    expect(bare.hour).toBe(10);
  });

  it("agrees for an evening hour too", () => {
    expect(local(resolve("kal 5").iso)!.hour).toBe(
      local(resolve("kal 5 baje").iso)!.hour,
    );
  });
});

describe("bug #3 — 'kal' and 'parso' follow the tense", () => {
  it("treats kal as tomorrow in the future tense", () => {
    expect(local(resolve("kal", { tense: "future" }).iso)!.day).toBe(24);
  });

  it("treats kal as yesterday in the past tense", () => {
    expect(local(resolve("kal", { tense: "past" }).iso)!.day).toBe(22);
  });

  it("treats parso both ways", () => {
    expect(local(resolve("parso", { tense: "future" }).iso)!.day).toBe(25);
    expect(local(resolve("parso", { tense: "past" }).iso)!.day).toBe(21);
  });

  it("records a past payment on the right day", () => {
    // "kal Rohan se payment aaya tha" — past tense.
    const dt = local(resolve("kal", { tense: "past" }).iso)!;
    expect(dt.day).toBe(22);
    expect(dt.month).toBe(8);
  });

  it("keeps English words unambiguous regardless of tense", () => {
    expect(local(resolve("yesterday", { tense: "future" }).iso)!.day).toBe(22);
    expect(local(resolve("tomorrow", { tense: "past" }).iso)!.day).toBe(24);
  });
});

describe("newly supported phrases", () => {
  it("resolves Hindi weekdays", () => {
    // Now is Saturday; next Somvar (Monday) is the 25th.
    expect(local(resolve("somvar").iso)!.day).toBe(25);
    expect(local(resolve("agle mangalvar").iso)!.day).toBe(26);
  });

  it("resolves a past Hindi weekday", () => {
    expect(local(resolve("pichhle somvar").iso)!.day).toBe(18);
  });

  it("resolves English weekdays", () => {
    expect(local(resolve("monday").iso)!.day).toBe(25);
  });

  it("resolves is/agle hafte", () => {
    expect(local(resolve("agle hafte").iso)!.day).toBe(30);
    expect(local(resolve("is hafte").iso)!.day).toBe(23);
    expect(local(resolve("pichhle hafte").iso)!.day).toBe(16);
  });

  it("resolves agle mahine", () => {
    const dt = local(resolve("agle mahine").iso)!;
    expect(dt.month).toBe(9);
  });

  it("resolves '15 tarikh'", () => {
    const dt = local(resolve("15 tarikh").iso)!;
    expect(dt.day).toBe(15);
    // The 15th has passed this month, so a future phrase rolls to September.
    expect(dt.month).toBe(9);
  });

  it("resolves 'agle mahine ki 5 tarikh'", () => {
    const dt = local(resolve("agle mahine ki 5 tarikh").iso)!;
    expect(dt.day).toBe(5);
    expect(dt.month).toBe(9);
  });
});

describe("phrases the old parser already handled", () => {
  it("resolves relative day counts", () => {
    expect(local(resolve("2 din baad").iso)!.day).toBe(25);
    expect(local(resolve("do din ke baad").iso)!.day).toBe(25);
    expect(local(resolve("after 3 days").iso)!.day).toBe(26);
    expect(local(resolve("3 din pehle").iso)!.day).toBe(20);
  });

  it("resolves numeric dates", () => {
    const dt = local(resolve("02/05/2026").iso)!;
    expect(dt.day).toBe(2);
    expect(dt.month).toBe(5);
    expect(dt.year).toBe(2026);
  });

  it("resolves named months", () => {
    const dt = local(resolve("5 May").iso)!;
    expect(dt.day).toBe(5);
    expect(dt.month).toBe(5);
    // May has passed in 2025, so a future phrase lands in 2026.
    expect(dt.year).toBe(2026);
  });

  it("resolves a past named month within the same year", () => {
    const dt = local(resolve("5 May", { tense: "past" }).iso)!;
    expect(dt.month).toBe(5);
    expect(dt.year).toBe(2025);
  });

  it("resolves am/pm and 24-hour clocks", () => {
    expect(local(resolve("kal 3:30pm").iso)!.hour).toBe(15);
    expect(local(resolve("kal 15:45").iso)!.minute).toBe(45);
    expect(local(resolve("kal 12am").iso)!.hour).toBe(0);
    expect(local(resolve("kal 12pm").iso)!.hour).toBe(12);
  });

  it("uses period defaults when no clock is given", () => {
    expect(local(resolve("kal subah").iso)!.hour).toBe(9);
    expect(local(resolve("kal shaam").iso)!.hour).toBe(18);
  });

  it("defaults a bare day to 11:00", () => {
    const r = resolve("kal");
    expect(local(r.iso)!.hour).toBe(11);
    expect(r.hasExplicitTime).toBe(false);
  });
});

describe("time without a day", () => {
  it("rolls a passed hour to tomorrow in the future tense", () => {
    // Now is 14:30; "9 baje" morning has gone, so it lands tomorrow.
    const dt = local(resolve("9 baje").iso)!;
    expect(dt.hour).toBe(9);
    expect(dt.day).toBe(24);
  });

  it("keeps a still-upcoming hour today", () => {
    const dt = local(resolve("6 baje").iso)!;
    expect(dt.hour).toBe(18);
    expect(dt.day).toBe(23);
  });

  it("looks backwards in the past tense", () => {
    const dt = local(resolve("6 baje", { tense: "past" }).iso)!;
    expect(dt.day).toBe(22);
  });
});

describe("empty and unreadable input", () => {
  it("returns nulls rather than guessing", () => {
    for (const phrase of ["", "   ", "kuch bhi", "new labels ke regarding"]) {
      const r = resolve(phrase);
      expect(r.iso).toBeNull();
      expect(r.epochMs).toBeNull();
      expect(r.label).toBeNull();
    }
  });
});

describe("labels are spelled out for the confirm card", () => {
  it("includes weekday, date and time", () => {
    expect(resolve("kal 11 baje").label).toBe("Ravivar, 24 August, 11:00 AM");
  });

  it("omits the clock when none was given", () => {
    expect(resolve("somvar").label).toContain("Somvar, 25 August");
  });
});

describe("normalizeName — parity with the Dart implementation", () => {
  it("drops filler particles as whole tokens", () => {
    expect(normalizeName("Rohan ka")).toBe("rohan");
    expect(normalizeName("Mr Rohan")).toBe("rohan");
    expect(normalizeName("Rohan se")).toBe("rohan");
    expect(normalizeName("the Rohan Traders")).toBe("rohan traders");
  });

  it("keeps particle-like substrings inside real words", () => {
    expect(normalizeName("Kamal")).toBe("kamal");
    expect(normalizeName("Kesari")).toBe("kesari");
  });

  it("strips edge punctuation and collapses spaces", () => {
    expect(normalizeName("  Rohan ,  Traders. ")).toBe("rohan traders");
    expect(normalizeName("Rohan!")).toBe("rohan");
  });

  it("handles null and empty input", () => {
    expect(normalizeName(null)).toBe("");
    expect(normalizeName(undefined)).toBe("");
    expect(normalizeName("   ")).toBe("");
  });

  it("returns empty when the name is only particles", () => {
    expect(normalizeName("ka ki ke")).toBe("");
  });

  it("capitalizes words for display", () => {
    expect(capitalizeWords("rohan traders")).toBe("Rohan Traders");
    expect(capitalizeWords("  rohan   ")).toBe("Rohan");
    expect(capitalizeWords("")).toBe("");
  });
});

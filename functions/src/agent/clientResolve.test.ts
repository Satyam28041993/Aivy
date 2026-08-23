import { describe, expect, it } from "vitest";

import { looksLikeNoiseClientName, normalizeForMatch } from "./clientResolve";

describe("normalizeForMatch", () => {
  it("trims and lowercases only — particles are kept", () => {
    expect(normalizeForMatch("  Rohan Traders ")).toBe("rohan traders");
    // Unlike normalizeName, this must NOT strip "ka".
    expect(normalizeForMatch("Rohan ka")).toBe("rohan ka");
  });
});

describe("looksLikeNoiseClientName", () => {
  it("rejects command words that reach a name slot by accident", () => {
    for (const w of ["cancel", "Band", "skip", "yes", "nahi", "confirm", "aivy", "hello"]) {
      expect(looksLikeNoiseClientName(w)).toBe(true);
    }
  });

  it("rejects bare numbers, which are menu picks and never names", () => {
    expect(looksLikeNoiseClientName("1")).toBe(true);
    expect(looksLikeNoiseClientName("12")).toBe(true);
  });

  it("rejects one-character input", () => {
    expect(looksLikeNoiseClientName("R")).toBe(true);
    expect(looksLikeNoiseClientName(" ")).toBe(true);
  });

  it("accepts real client names", () => {
    for (const n of ["Rohan", "Rohan Traders", "Prakruti Graphic", "PGPL"]) {
      expect(looksLikeNoiseClientName(n)).toBe(false);
    }
  });
});

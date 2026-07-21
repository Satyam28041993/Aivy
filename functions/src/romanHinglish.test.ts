import { describe, expect, it } from "vitest";

import { containsDevanagari } from "./romanHinglish";

describe("containsDevanagari", () => {
  it("detects Hindi script", () => {
    expect(containsDevanagari("ठीक है")).toBe(true);
    expect(containsDevanagari("Theek hai")).toBe(false);
    expect(containsDevanagari("Mix ठीक ok")).toBe(true);
  });
});

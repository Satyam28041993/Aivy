/**
 * The cost shown in Settings is Gemini's own token counts at the published
 * price — pinned here so a price edit is a visible, tested change.
 */

import { describe, expect, it, vi } from "vitest";

vi.mock("firebase-admin/firestore", () => ({ getFirestore: vi.fn() }));
vi.mock("firebase-functions", () => ({ logger: { warn: vi.fn() } }));

const { addUsage, costUsd, EMPTY_USAGE } = await import("./aiUsage");

describe("AI usage", () => {
  it("adds every hop of a turn together", () => {
    let u = addUsage(EMPTY_USAGE, { promptTokenCount: 9000, candidatesTokenCount: 40 });
    u = addUsage(u, { promptTokenCount: 9500, candidatesTokenCount: 120, thoughtsTokenCount: 300 });
    expect(u).toEqual({ inputTokens: 18500, outputTokens: 160, thinkingTokens: 300, cachedTokens: 0, calls: 2 });
  });

  it("survives a response with no usage block", () => {
    expect(addUsage(EMPTY_USAGE, undefined).calls).toBe(1);
  });

  it("prices Flash at $0.30 in, $2.50 out (thinking included), cache at a tenth", () => {
    const usd = costUsd("gemini-2.5-flash", {
      inputTokens: 1_000_000,
      outputTokens: 600_000,
      thinkingTokens: 400_000,
      cachedTokens: 0,
      calls: 1,
    });
    expect(usd).toBeCloseTo(0.3 + 2.5, 6);
    const cached = costUsd("gemini-2.5-flash", {
      inputTokens: 1_000_000,
      outputTokens: 0,
      thinkingTokens: 0,
      cachedTokens: 1_000_000,
      calls: 1,
    });
    expect(cached).toBeCloseTo(0.03, 6);
  });
});

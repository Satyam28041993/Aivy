import { describe, expect, it } from "vitest";
import { riskFromAvgDelayDay } from "./clientStats";

describe("riskFromAvgDelayDay", () => {
  it("marks no payment history as average", () => {
    expect(riskFromAvgDelayDay(0, 0)).toBe("average");
  });
  it("treats zero avg as good when paid", () => {
    expect(riskFromAvgDelayDay(0, 2)).toBe("good");
  });
  it("1–5 days average", () => {
    expect(riskFromAvgDelayDay(1, 1)).toBe("average");
    expect(riskFromAvgDelayDay(5, 1)).toBe("average");
  });
  it("over 5 days risky", () => {
    expect(riskFromAvgDelayDay(5.1, 1)).toBe("risky");
  });
});

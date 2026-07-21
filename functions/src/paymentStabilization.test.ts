import { describe, expect, it } from "vitest";
import { _paymentStabilizationTest } from "./aivyProcess";

const {
  tryExtractManualPaymentForFirestore,
  formatPaymentList,
  getPaymentAnalyticsTimeWindow,
  isPaymentTotalOutstandingQuery,
  normalizeAnalyticsText,
  buildTimeContext,
  isPaymentQueryOnlyIntentText,
  isBareGenericPaymentDueQuestion,
} = _paymentStabilizationTest;

const ctx = buildTimeContext({
  timezone: "Asia/Kolkata",
  nowIso: "2026-04-25T10:00:00+05:30",
});

describe("Phase 2 payment stabilization", () => {
  it("1) Ramesh ka 50000 baaki hai — extracts client, amount, default due today (0 days offset)", () => {
    const r = tryExtractManualPaymentForFirestore("Ramesh ka 50000 baaki hai");
    expect(r).not.toBeNull();
    expect(r!.displayClient).toBe("Ramesh");
    expect(r!.amount).toBe(50000);
    expect(r!.days).toBe(0);
  });

  it("2) Aaj kaun se payment due hai — today window", () => {
    const w = getPaymentAnalyticsTimeWindow("Aaj kaun se payment due hai", ctx);
    expect(w.label).toMatch(/aaj/i);
  });

  it("3) Is month total kitna due — current month window (not global outstanding)", () => {
    const t = normalizeAnalyticsText("Is month total kitna due hai");
    expect(isPaymentTotalOutstandingQuery("", t)).toBe(false);
    const w = getPaymentAnalyticsTimeWindow("is month total kitna due", ctx);
    expect(w.label).toBe("is maahine");
  });

  it("4) Next month ka due dikhao", () => {
    const w = getPaymentAnalyticsTimeWindow("next month ka due dikhao", ctx);
    expect(w.label).toMatch(/agle|mahina|month/i);
  });

  it("5) Kaun se payment overdue — overdue / past window, not total-outstanding", () => {
    const t = normalizeAnalyticsText("kaun se payment overdue hai");
    expect(isPaymentTotalOutstandingQuery("", t)).toBe(false);
  });

  it("6) Total outstanding — global pending-sum intent", () => {
    const raw = "Total outstanding kitna hai";
    const t = normalizeAnalyticsText(raw);
    expect(isPaymentTotalOutstandingQuery(raw, t)).toBe(true);
  });

  it("7) Ramesh ka payment kab due — not global outstanding, client query shape", () => {
    const t = normalizeAnalyticsText("Ramesh ka payment kab due hai");
    expect(isPaymentTotalOutstandingQuery("", t)).toBe(false);
  });

  it("formatPaymentList strict shape (grouped by client)", () => {
    const s = formatPaymentList(
      [
        { client: "Ramesh", amount: 50_000, dueDateLabel: "25 Apr" },
        { client: "Ajay", amount: 30_000, dueDateLabel: "28 Apr" },
        { client: "Ramesh", amount: 50_000, dueDateLabel: "27 Apr" },
      ],
    );
    expect(s).toContain("Ramesh");
    expect(s).toContain("50,000");
    expect(s).toContain("25 Apr");
    expect(s).toContain("Ajay");
    expect(s).toMatch(/Ramesh[\s\S]*₹50,000 — 25 Apr[\s\S]*₹50,000 — 27 Apr/);
  });

  it("8) Ramesh kab due — query only", () => {
    expect(isPaymentQueryOnlyIntentText("Ramesh ka payment kab due hai")).toBe(
      true,
    );
  });

  it("9) manual entry with amount is not query-only", () => {
    expect(tryExtractManualPaymentForFirestore("Ramesh ka 50000 baaki hai")).not.toBeNull();
    expect(isPaymentQueryOnlyIntentText("Ramesh ka 50000 baaki hai")).toBe(false);
  });

  it("10) bare payment due ask — clarify", () => {
    expect(isBareGenericPaymentDueQuestion("payment due hai")).toBe(true);
    expect(isBareGenericPaymentDueQuestion("Aaj kaun se payment due hai")).toBe(
      false,
    );
  });
});

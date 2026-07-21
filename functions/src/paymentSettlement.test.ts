import { describe, expect, it } from "vitest";
import {
  effectiveOriginalAmount,
  effectivePaidAmount,
  effectiveRemainingAmount,
  isOpenDueStatus,
  isOpenPaymentDueDoc,
  isVoidedReceipt,
  openDueRollupAmount,
} from "./paymentSettlement";

describe("paymentSettlement", () => {
  it("isOpenDueStatus includes partial_pending", () => {
    expect(isOpenDueStatus("partial_pending")).toBe(true);
    expect(isOpenDueStatus("received")).toBe(false);
    expect(isOpenDueStatus("cancelled")).toBe(false);
  });

  it("effectiveRemainingAmount prefers remainingAmount", () => {
    expect(
      effectiveRemainingAmount({
        originalAmount: 1000,
        paidAmount: 200,
        remainingAmount: 750,
      }),
    ).toBe(750);
  });

  it("effectiveRemainingAmount falls back to original minus paid", () => {
    expect(
      effectiveRemainingAmount({
        originalAmount: 1000,
        paidAmount: 300,
      }),
    ).toBe(700);
  });

  it("effectiveOriginalAmount falls back to amount", () => {
    expect(effectiveOriginalAmount({ amount: 500 })).toBe(500);
  });

  it("effectivePaidAmount defaults to 0", () => {
    expect(effectivePaidAmount({})).toBe(0);
  });

  it("isOpenPaymentDueDoc excludes payment_received", () => {
    expect(
      isOpenPaymentDueDoc({
        type: "payment",
        subType: "payment_received",
        status: "pending",
      }),
    ).toBe(false);
  });

  it("openDueRollupAmount uses remaining for open dues", () => {
    expect(
      openDueRollupAmount({
        type: "payment_due",
        subType: "payment_due",
        status: "partial_pending",
        originalAmount: 10000,
        paidAmount: 4000,
        remainingAmount: 6000,
      }),
    ).toBe(6000);
  });

  it("openDueRollupAmount is 0 for closed status", () => {
    expect(
      openDueRollupAmount({
        type: "payment_due",
        subType: "payment_due",
        status: "received",
        remainingAmount: 0,
      }),
    ).toBe(0);
  });

  it("isVoidedReceipt", () => {
    expect(isVoidedReceipt({ voided: true })).toBe(true);
    expect(isVoidedReceipt({ voided: false })).toBe(false);
    expect(isVoidedReceipt({})).toBe(false);
  });
});

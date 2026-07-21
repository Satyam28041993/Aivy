import type { DocumentData } from "firebase-admin/firestore";

/** Open due statuses — matches Flutter [PaymentRecord.isOpenPaymentDue]. */
export const OPEN_DUE_STATUSES = new Set([
  "pending",
  "overdue",
  "partial_pending",
  "",
  "open",
  "active",
]);

export function isOpenDueStatus(status: unknown): boolean {
  const s = String(status ?? "")
    .trim()
    .toLowerCase();
  return OPEN_DUE_STATUSES.has(s);
}

export function isVoidedReceipt(d: DocumentData): boolean {
  return (d as { voided?: unknown }).voided === true;
}

export function effectiveOriginalAmount(d: DocumentData): number {
  const o = Number((d as { originalAmount?: unknown }).originalAmount);
  if (Number.isFinite(o) && o > 0) {
    return o;
  }
  const a = Number((d as { amount?: unknown }).amount);
  return Number.isFinite(a) && a > 0 ? a : 0;
}

export function effectivePaidAmount(d: DocumentData): number {
  const p = Number((d as { paidAmount?: unknown }).paidAmount);
  return Number.isFinite(p) && p >= 0 ? p : 0;
}

/** Remaining collectible on a **due** row (fallback when v2 fields missing). */
export function effectiveRemainingAmount(d: DocumentData): number {
  const r = Number((d as { remainingAmount?: unknown }).remainingAmount);
  if (Number.isFinite(r) && r >= 0) {
    return r;
  }
  return Math.max(0, effectiveOriginalAmount(d) - effectivePaidAmount(d));
}

export function normalizeFirestorePaymentSubType(d: DocumentData): string {
  const raw = (d as { subType?: unknown }).subType;
  const s = String(raw ?? "").trim().toLowerCase();
  return s.length > 0 ? s : "payment_due";
}

export function normalizeFirestorePaymentType(d: DocumentData): string {
  const raw = (d as { type?: unknown }).type;
  const s = String(raw ?? "").trim().toLowerCase();
  return s.length > 0 ? s : "payment";
}

/** Open amount rows only — matches Flutter [PaymentRecord.isOpenPaymentDue]. */
export function isOpenPaymentDueDoc(d: DocumentData): boolean {
  if (!isOpenDueStatus((d as { status?: unknown }).status)) {
    return false;
  }
  const stp = normalizeFirestorePaymentSubType(d);
  if (stp === "payment_received") {
    return false;
  }
  const ty = normalizeFirestorePaymentType(d);
  if (ty === "payment_due") {
    return true;
  }
  if (ty === "payment" && (stp === "payment_due" || stp === "payment")) {
    return true;
  }
  return false;
}

/** Outstanding total for rollups / analytics (dues only, uses remaining). */
export function openDueRollupAmount(d: DocumentData): number {
  if (!isOpenPaymentDueDoc(d)) {
    return 0;
  }
  return effectiveRemainingAmount(d);
}

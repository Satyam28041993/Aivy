/**
 * Travel expenses — the kilometres the user rides to Great Eastern visits,
 * claimed per km.
 *
 * One record per day, `users/{uid}/travelExpenses/{yyyy-MM-dd}`: the start
 * point they named, then each visit of that day in order, then back. Every leg
 * is measured on Google Maps and becomes its own row in "Aivy Expenses", a
 * Google Sheet in their Drive that they hand to the company — point-wise, the
 * way they asked for it.
 *
 * Same shape as the DSR (`visitStore.ts`): Firestore is the record, the sheet a
 * copy that catches up on the next save that carries a Google token.
 *
 * The rate is Great Eastern's bike rate, ₹4 a km, until the policy is known in
 * full. `meta/expenseSettings` overrides it without a deploy.
 */

import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { DateTime } from "luxon";

import { GoogleApiError, sheetsAppendRowsRaw, sheetsCreate } from "./google/workspace";

export const TRAVEL_EXPENSES = "travelExpenses";
export const EXPENSE_TAB = "Travel";
export const EXPENSE_TITLE = "Aivy Expenses - Great Eastern travel";

export const DEFAULT_RATE_PER_KM = 4;
export const DEFAULT_VEHICLE = "Bike";

/** The sheet's columns, in order. The company sees these headings. */
export const EXPENSE_HEADER = [
  "Date",
  "From",
  "To",
  "Purpose / Client",
  "Vehicle",
  "Km",
  "Rate (₹/km)",
  "Amount (₹)",
  "Day Total Km",
  "Day Total (₹)",
  "Recorded At",
];

export interface ExpenseLeg {
  from: string;
  to: string;
  /** Client visited at the end of this leg, or "Return" for the way back. */
  purpose: string;
  km: number;
  amount: number;
}

export interface TravelExpense {
  /** yyyy-MM-dd in the user's zone. */
  id: string;
  dateMs: number;
  /** "06-Oct-2026", as it goes on the sheet. */
  dateLabel: string;
  startPoint: string;
  endPoint: string;
  vehicle: string;
  ratePerKm: number;
  legs: ExpenseLeg[];
  totalKm: number;
  totalAmount: number;
  createdAtMs: number;
  /** First sheet row once copied; null while it waits for a Google token. */
  sheetRow: number | null;
}

export interface ExpenseSettings {
  ratePerKm: number;
  vehicle: string;
}

function expensesRef(uid: string) {
  return getFirestore().collection("users").doc(uid).collection(TRAVEL_EXPENSES);
}

function metaRef(uid: string, id: string) {
  return getFirestore().collection("users").doc(uid).collection("meta").doc(id);
}

export function dayKey(ms: number, timezone: string): string {
  return DateTime.fromMillis(ms, { zone: timezone }).toFormat("yyyy-MM-dd");
}

/** Id of the 8 PM "expense entry" reminder for a day — one per day. */
export function expensePromptId(day: string): string {
  return `expense-prompt-${day}`;
}

/** Rupees to the paisa, so a sum of legs equals the day's total. */
export function rupees(n: number): number {
  return Math.round(n * 100) / 100;
}

/** Fills in amounts and totals from the legs' kilometres. */
export function priceLegs(
  legs: Array<Omit<ExpenseLeg, "amount">>,
  ratePerKm: number,
): { legs: ExpenseLeg[]; totalKm: number; totalAmount: number } {
  const priced = legs.map((l) => ({ ...l, amount: rupees(l.km * ratePerKm) }));
  const totalKm = Math.round(priced.reduce((a, l) => a + l.km, 0) * 10) / 10;
  const totalAmount = rupees(priced.reduce((a, l) => a + l.amount, 0));
  return { legs: priced, totalKm, totalAmount };
}

export async function expenseSettings(uid: string): Promise<ExpenseSettings> {
  try {
    const d = (await metaRef(uid, "expenseSettings").get()).data() ?? {};
    const rate = typeof d.ratePerKm === "number" && d.ratePerKm > 0 ? d.ratePerKm : DEFAULT_RATE_PER_KM;
    const vehicle = typeof d.vehicle === "string" && d.vehicle.trim() ? d.vehicle.trim() : DEFAULT_VEHICLE;
    return { ratePerKm: rate, vehicle };
  } catch {
    return { ratePerKm: DEFAULT_RATE_PER_KM, vehicle: DEFAULT_VEHICLE };
  }
}

/**
 * One row per leg. The day's totals go on its last leg only, so summing the
 * Amount column still gives the claim and nothing is counted twice.
 */
export function expenseToRows(e: TravelExpense, timezone: string): string[][] {
  const recorded = DateTime.fromMillis(e.createdAtMs, { zone: timezone }).toFormat("dd-LLL-yyyy h:mm a");
  return e.legs.map((l, i) => {
    const last = i === e.legs.length - 1;
    return [
      e.dateLabel,
      l.from,
      l.to,
      l.purpose,
      e.vehicle,
      String(l.km),
      String(e.ratePerKm),
      String(l.amount),
      last ? String(e.totalKm) : "",
      last ? String(e.totalAmount) : "",
      recorded,
    ];
  });
}

function fromDoc(id: string, d: Record<string, unknown>): TravelExpense {
  const s = (k: string) => (typeof d[k] === "string" ? (d[k] as string) : "");
  const n = (k: string) => (typeof d[k] === "number" ? (d[k] as number) : 0);
  const legs = Array.isArray(d.legs) ? (d.legs as ExpenseLeg[]) : [];
  return {
    id,
    dateMs: n("dateMs"),
    dateLabel: s("dateLabel"),
    startPoint: s("startPoint"),
    endPoint: s("endPoint"),
    vehicle: s("vehicle"),
    ratePerKm: n("ratePerKm"),
    legs,
    totalKm: n("totalKm"),
    totalAmount: n("totalAmount"),
    createdAtMs: n("createdAtMs"),
    sheetRow: typeof d.sheetRow === "number" ? d.sheetRow : null,
  };
}

export async function getExpense(uid: string, day: string): Promise<TravelExpense | null> {
  const snap = await expensesRef(uid).doc(day).get();
  return snap.exists ? fromDoc(snap.id, snap.data() ?? {}) : null;
}

export async function saveExpense(
  uid: string,
  e: Omit<TravelExpense, "createdAtMs" | "sheetRow">,
): Promise<TravelExpense> {
  const record: TravelExpense = { ...e, createdAtMs: Date.now(), sheetRow: null };
  const { id, ...data } = record;
  await expensesRef(uid).doc(id).set(data);
  return record;
}

/**
 * Whether today's 8 PM "where did you start?" is still unanswered: the prompt
 * reminder was set (so there were visits) and no travel is saved for today.
 * The model is told, so whatever place he names next is read as the answer.
 */
export async function expenseAwaitingStart(uid: string, nowMs: number, timezone: string): Promise<boolean> {
  const day = dayKey(nowMs, timezone);
  const [prompt, saved] = await Promise.all([
    getFirestore().collection("users").doc(uid).collection("reminders").doc(expensePromptId(day)).get(),
    expensesRef(uid).doc(day).get(),
  ]);
  if (!prompt.exists || saved.exists) return false;
  const at = Number(prompt.get("scheduledTimeMs") ?? 0);
  // Before 8 PM it has not been asked yet; a stray place name then means a place.
  return at > 0 && nowMs >= at - 30 * 60 * 1000;
}

export async function listExpenses(
  uid: string,
  opts: { fromMs: number; toMs: number },
): Promise<TravelExpense[]> {
  const snap = await expensesRef(uid)
    .where("dateMs", ">=", opts.fromMs)
    .where("dateMs", "<", opts.toMs)
    .orderBy("dateMs", "desc")
    .limit(100)
    .get();
  return snap.docs.map((d) => fromDoc(d.id, d.data()));
}

export async function expenseSheetLink(uid: string): Promise<string | null> {
  const url = (await metaRef(uid, "expenseSheet").get()).data()?.url;
  return typeof url === "string" && url ? url : null;
}

async function ensureExpenseSheet(
  uid: string,
  token: string,
): Promise<{ spreadsheetId: string; url: string; created: boolean }> {
  const snap = await metaRef(uid, "expenseSheet").get();
  const id = `${snap.data()?.spreadsheetId ?? ""}`;
  if (id) {
    return { spreadsheetId: id, url: `${snap.data()?.url ?? ""}`, created: false };
  }
  const made = await sheetsCreate(token, { title: EXPENSE_TITLE, tab: EXPENSE_TAB, header: EXPENSE_HEADER });
  await metaRef(uid, "expenseSheet").set({ spreadsheetId: made.spreadsheetId, url: made.url, createdAtMs: Date.now() });
  return { ...made, created: true };
}

export interface ExpenseSyncResult {
  written: number;
  url: string | null;
  created: boolean;
  problem: string | null;
}

/** Copies every day not yet in the sheet, oldest first. Never throws. */
export async function syncExpensesToSheet(
  uid: string,
  token: string | null | undefined,
  timezone: string,
): Promise<ExpenseSyncResult> {
  if (!token) {
    return {
      written: 0,
      url: await expenseSheetLink(uid).catch(() => null),
      created: false,
      problem: "Google is not connected on this device, so the expense sheet will catch up next time.",
    };
  }
  try {
    let sheet = await ensureExpenseSheet(uid, token);
    const pending = await expensesRef(uid).where("sheetRow", "==", null).get();
    const days = pending.docs
      .map((d) => fromDoc(d.id, d.data()))
      .filter((e) => e.legs.length > 0)
      .sort((a, b) => a.dateMs - b.dateMs);
    if (days.length === 0) {
      return { written: 0, url: sheet.url || null, created: sheet.created, problem: null };
    }
    const rows = days.flatMap((e) => expenseToRows(e, timezone));
    const append = () =>
      sheetsAppendRowsRaw(token, { spreadsheetId: sheet.spreadsheetId, tab: EXPENSE_TAB, rows });
    let first: number | null;
    try {
      first = await append();
    } catch (e) {
      // Deleted sheet or renamed tab: start a fresh one, as the DSR does.
      if (e instanceof GoogleApiError && (e.status === 404 || e.status === 400)) {
        await metaRef(uid, "expenseSheet").delete();
        sheet = await ensureExpenseSheet(uid, token);
        first = await append();
      } else {
        throw e;
      }
    }
    const batch = getFirestore().batch();
    let row = first ?? -1;
    for (const e of days) {
      batch.update(expensesRef(uid).doc(e.id), { sheetRow: row });
      if (row > 0) row += e.legs.length;
    }
    await batch.commit();
    return { written: rows.length, url: sheet.url || null, created: sheet.created, problem: null };
  } catch (e) {
    logger.warn("syncExpensesToSheet failed", { err: e instanceof Error ? e.message : String(e) });
    return {
      written: 0,
      url: await expenseSheetLink(uid).catch(() => null),
      created: false,
      problem:
        e instanceof GoogleApiError
          ? `the expense sheet could not be updated — ${e.userMessage}`
          : "the expense sheet could not be updated just now; it will catch up on the next save.",
    };
  }
}

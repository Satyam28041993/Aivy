/**
 * Birthdays, anniversaries — the dates that come back every year.
 *
 * A reminder is a moment; an occasion is a date without a year, and the two
 * cannot be the same record. A birthday set as a reminder fires once and is
 * then gone forever, which is exactly the wrong behaviour for the one kind of
 * date that is certain to come round again.
 *
 * So only the day and month are stored, plus the year of birth when it is
 * known — useful for "she turns 31" — and the next occurrence is computed each
 * time rather than written down and left to go stale.
 */

import { getFirestore } from "firebase-admin/firestore";
import { DateTime } from "luxon";

import { normalizeName } from "./nameNormalize";

export type OccasionKind = "birthday" | "anniversary" | "other";

export interface Occasion {
  id: string;
  /** "Ruchi", "Prisha", "our wedding". */
  name: string;
  nameKey: string;
  kind: OccasionKind;
  /** 1-12 and 1-31. No year: that is the whole point. */
  month: number;
  day: number;
  /** Year of the original event, when known. 0 when it is not. */
  year: number;
  createdAtMs: number;
}

/** How many days before the day itself the user is warned. */
export const LEAD_DAYS = [15, 10, 5, 1, 0] as const;

function occasionsRef(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("occasions");
}

export function isValidDayMonth(day: number, month: number): boolean {
  if (!Number.isInteger(day) || !Number.isInteger(month)) {
    return false;
  }
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    return false;
  }
  // 31 April is a typo, not a date. February keeps 29 — a leap-year birthday
  // is real, and the next-occurrence maths handles the years it is missing.
  const longest = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]!;
  return day <= longest;
}

export async function saveOccasion(
  uid: string,
  input: {
    name: string;
    kind: OccasionKind;
    day: number;
    month: number;
    year?: number | null;
  },
): Promise<Occasion> {
  const name = input.name.trim();
  const nameKey = normalizeName(name);
  const now = Date.now();

  // Saving the same person again moves the date rather than leaving two rows
  // that will both fire, a day apart, arguing with each other.
  const existing = await occasionsRef(uid).where("nameKey", "==", nameKey).limit(1).get();
  const ref = existing.empty ? occasionsRef(uid).doc() : existing.docs[0]!.ref;

  const row: Occasion = {
    id: ref.id,
    name,
    nameKey,
    kind: input.kind,
    month: input.month,
    day: input.day,
    year: input.year && input.year > 1900 ? input.year : 0,
    createdAtMs: now,
  };
  await ref.set(row, { merge: true });
  return row;
}

export async function listOccasions(uid: string, limit = 100): Promise<Occasion[]> {
  const snap = await occasionsRef(uid).limit(limit).get();
  return snap.docs.map((d) => d.data() as Occasion);
}

export async function findOccasion(uid: string, name: string): Promise<Occasion | null> {
  const key = normalizeName(name);
  if (!key) {
    return null;
  }
  const exact = await occasionsRef(uid).where("nameKey", "==", key).limit(1).get();
  if (!exact.empty) {
    return exact.docs[0]!.data() as Occasion;
  }
  // "Ruchi" should find "Ruchi Singh", but only when nothing else could be meant.
  const all = await listOccasions(uid);
  const partial = all.filter((o) => o.nameKey.includes(key) || key.includes(o.nameKey));
  return partial.length === 1 ? partial[0]! : null;
}

export async function deleteOccasion(uid: string, name: string): Promise<boolean> {
  const found = await findOccasion(uid, name);
  if (!found) {
    return false;
  }
  await occasionsRef(uid).doc(found.id).delete();
  return true;
}

/**
 * The next time this date comes round, in the user's own zone.
 *
 * Today counts as today, not as a year away — a birthday is not "in 365 days"
 * on the morning of it.
 */
export function nextOccurrence(
  o: Pick<Occasion, "day" | "month">,
  timezone: string,
  nowMs = Date.now(),
): DateTime {
  const zone = timezone || "Asia/Kolkata";
  const today = DateTime.fromMillis(nowMs, { zone }).startOf("day");
  let candidate = DateTime.fromObject(
    { year: today.year, month: o.month, day: o.day },
    { zone },
  );
  // 29 February in a common year lands on 1 March, which is where Luxon puts
  // it and where most people mark it.
  if (!candidate.isValid) {
    candidate = DateTime.fromObject({ year: today.year, month: 3, day: 1 }, { zone });
  }
  if (candidate < today) {
    candidate = candidate.plus({ years: 1 });
    if (!candidate.isValid) {
      candidate = DateTime.fromObject({ year: today.year + 1, month: 3, day: 1 }, { zone });
    }
  }
  return candidate;
}

/** Whole days from today to the next occurrence, in the user's zone. */
export function daysUntil(
  o: Pick<Occasion, "day" | "month">,
  timezone: string,
  nowMs = Date.now(),
): number {
  const zone = timezone || "Asia/Kolkata";
  const today = DateTime.fromMillis(nowMs, { zone }).startOf("day");
  return Math.round(nextOccurrence(o, timezone, nowMs).diff(today, "days").days);
}

/** "31st birthday" — only when the original year is known. */
export function milestoneLabel(o: Occasion, timezone: string, nowMs = Date.now()): string {
  if (o.year <= 0) {
    return "";
  }
  const years = nextOccurrence(o, timezone, nowMs).year - o.year;
  if (years <= 0) {
    return "";
  }
  return o.kind === "anniversary" ? `${years} years` : `turning ${years}`;
}

/**
 * Client visits — the user's daily sales report (DSR) for Great Eastern.
 *
 * Every visit is kept twice, on purpose:
 *   - in Firestore, `users/{uid}/visits/{id}`, which is what Aivy reads back
 *     ("is hafte kitne visits", "Bajaj me pichhli baar kya hua tha");
 *   - as a row in a Google Sheet in the user's own Drive, "Aivy DSR", which is
 *     what they show their company.
 *
 * The Firestore row is the record; the sheet is a copy. Google is only
 * reachable on a turn that carried the user's token (Android), so a visit
 * saved without one is kept with `sheetRow: null` and copied across on the
 * next save that has a token — nothing is lost to a missing permission, and
 * the sheet catches up by itself.
 */

import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { DateTime } from "luxon";

import {
  GoogleApiError,
  sheetsAppendRowsRaw,
  sheetsCreate,
  sheetsUpdateRow,
} from "./google/workspace";

export const VISITS = "visits";
export const DSR_TAB = "DSR";
export const DSR_TITLE = "Aivy DSR - Great Eastern visits";

/** The sheet's columns, in order. The company sees these headings. */
export const DSR_HEADER = [
  "Date",
  "Client / Company",
  "Contact Person",
  "Contact No.",
  "Location",
  "Visit Type",
  "Products Discussed",
  "Discussion / Remarks",
  "Status",
  "Next Step",
  "Follow-up Date",
  "Recorded At",
];
/** 1-based column of "Follow-up Date", for the later update. */
export const FOLLOW_UP_COLUMN = DSR_HEADER.indexOf("Follow-up Date") + 1;

export interface VisitRecord {
  id: string;
  visitDateMs: number;
  /** "06-Oct-2026", as it goes on the sheet. */
  dateLabel: string;
  clientId: string;
  clientName: string;
  contactPerson: string;
  contactPhone: string;
  location: string;
  /** The phone's fix when the location came from it — routes the expense. */
  lat: number | null;
  lng: number | null;
  visitType: string;
  products: string;
  discussion: string;
  status: string;
  nextStep: string;
  followUpMs: number;
  followUpLabel: string;
  followUpReminderId: string;
  createdAtMs: number;
  /** Sheet row once copied; null while it waits for a Google token. */
  sheetRow: number | null;
  /** The sheet row's follow-up cell is behind the record. */
  sheetFollowUpPending: boolean;
}

function visitsRef(uid: string) {
  return getFirestore().collection("users").doc(uid).collection(VISITS);
}

function dsrMetaRef(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("meta").doc("dsr");
}

export function sheetDate(ms: number, timezone: string): string {
  return DateTime.fromMillis(ms, { zone: timezone }).toFormat("dd-LLL-yyyy");
}

/** One visit as a sheet row, in DSR_HEADER order. */
export function visitToRow(v: VisitRecord, timezone: string): string[] {
  return [
    v.dateLabel,
    v.clientName,
    v.contactPerson,
    v.contactPhone,
    v.location,
    v.visitType,
    v.products,
    v.discussion,
    v.status,
    v.nextStep,
    v.followUpMs > 0 ? sheetDate(v.followUpMs, timezone) : "",
    DateTime.fromMillis(v.createdAtMs, { zone: timezone }).toFormat("dd-LLL-yyyy h:mm a"),
  ];
}

function fromDoc(id: string, d: Record<string, unknown>): VisitRecord {
  const s = (k: string) => (typeof d[k] === "string" ? (d[k] as string) : "");
  const n = (k: string) => (typeof d[k] === "number" ? (d[k] as number) : 0);
  return {
    id,
    visitDateMs: n("visitDateMs"),
    dateLabel: s("dateLabel"),
    clientId: s("clientId"),
    clientName: s("clientName"),
    contactPerson: s("contactPerson"),
    contactPhone: s("contactPhone"),
    location: s("location"),
    lat: typeof d.lat === "number" ? d.lat : null,
    lng: typeof d.lng === "number" ? d.lng : null,
    visitType: s("visitType"),
    products: s("products"),
    discussion: s("discussion"),
    status: s("status"),
    nextStep: s("nextStep"),
    followUpMs: n("followUpMs"),
    followUpLabel: s("followUpLabel"),
    followUpReminderId: s("followUpReminderId"),
    createdAtMs: n("createdAtMs"),
    sheetRow: typeof d.sheetRow === "number" ? d.sheetRow : null,
    sheetFollowUpPending: d.sheetFollowUpPending === true,
  };
}

export async function saveVisit(
  uid: string,
  v: Omit<VisitRecord, "id" | "sheetRow" | "sheetFollowUpPending" | "createdAtMs">,
): Promise<VisitRecord> {
  const ref = visitsRef(uid).doc();
  const record: VisitRecord = {
    ...v,
    id: ref.id,
    createdAtMs: Date.now(),
    sheetRow: null,
    sheetFollowUpPending: false,
  };
  const { id: _id, ...data } = record;
  void _id;
  await ref.set({ ...data, clientNameLower: v.clientName.toLowerCase() });
  return record;
}

export async function getVisit(uid: string, id: string): Promise<VisitRecord | null> {
  const snap = await visitsRef(uid).doc(id).get();
  return snap.exists ? fromDoc(snap.id, snap.data() ?? {}) : null;
}

export async function latestVisit(uid: string): Promise<VisitRecord | null> {
  const snap = await visitsRef(uid).orderBy("createdAtMs", "desc").limit(1).get();
  const doc = snap.docs[0];
  return doc ? fromDoc(doc.id, doc.data()) : null;
}

export async function listVisits(
  uid: string,
  opts: { fromMs: number; toMs: number; clientLower?: string; limit?: number },
): Promise<VisitRecord[]> {
  const snap = await visitsRef(uid)
    .where("visitDateMs", ">=", opts.fromMs)
    .where("visitDateMs", "<", opts.toMs)
    .orderBy("visitDateMs", "desc")
    .limit(opts.limit ?? 200)
    .get();
  const rows = snap.docs.map((d) => fromDoc(d.id, d.data()));
  if (!opts.clientLower) return rows;
  return rows.filter((r) => r.clientName.toLowerCase().includes(opts.clientLower!));
}

export async function setVisitFollowUp(
  uid: string,
  id: string,
  f: { followUpMs: number; followUpLabel: string; reminderId: string },
): Promise<void> {
  await visitsRef(uid).doc(id).update({
    followUpMs: f.followUpMs,
    followUpLabel: f.followUpLabel,
    followUpReminderId: f.reminderId,
    sheetFollowUpPending: true,
  });
}

export async function dsrSheetLink(uid: string): Promise<string | null> {
  const snap = await dsrMetaRef(uid).get();
  const url = snap.data()?.url;
  return typeof url === "string" && url ? url : null;
}

/** Finds the DSR sheet, or makes it on the first visit ever saved. */
async function ensureDsrSheet(
  uid: string,
  token: string,
): Promise<{ spreadsheetId: string; url: string; created: boolean }> {
  const snap = await dsrMetaRef(uid).get();
  const id = `${snap.data()?.spreadsheetId ?? ""}`;
  if (id) {
    return { spreadsheetId: id, url: `${snap.data()?.url ?? ""}`, created: false };
  }
  const made = await sheetsCreate(token, { title: DSR_TITLE, tab: DSR_TAB, header: DSR_HEADER });
  await dsrMetaRef(uid).set({ spreadsheetId: made.spreadsheetId, url: made.url, createdAtMs: Date.now() });
  return { ...made, created: true };
}

export interface SheetSyncResult {
  /** Rows written or updated on this pass. */
  written: number;
  url: string | null;
  created: boolean;
  /** Why the sheet could not be reached, in the user's terms. */
  problem: string | null;
}

/**
 * Brings the sheet up to date: copies every visit that has no row yet (oldest
 * first) and rewrites rows whose follow-up was added later. Best-effort — the
 * Firestore record is already safe, so a Google failure is reported, never
 * thrown.
 */
export async function syncVisitsToSheet(
  uid: string,
  token: string | null | undefined,
  timezone: string,
): Promise<SheetSyncResult> {
  if (!token) {
    return {
      written: 0,
      url: await dsrSheetLink(uid).catch(() => null),
      created: false,
      problem: "Google is not connected on this device, so the DSR sheet will catch up next time.",
    };
  }
  try {
    let sheet = await ensureDsrSheet(uid, token);
    const pending = await visitsRef(uid).where("sheetRow", "==", null).get();
    const unsynced = pending.docs
      .map((d) => fromDoc(d.id, d.data()))
      .sort((a, b) => a.createdAtMs - b.createdAtMs);

    let written = 0;
    if (unsynced.length > 0) {
      let first: number | null;
      try {
        first = await sheetsAppendRowsRaw(token, {
          spreadsheetId: sheet.spreadsheetId,
          tab: DSR_TAB,
          rows: unsynced.map((v) => visitToRow(v, timezone)),
        });
      } catch (e) {
        // The sheet was deleted or its tab renamed: start a fresh one rather
        // than failing every save from now on.
        if (e instanceof GoogleApiError && (e.status === 404 || e.status === 400)) {
          await dsrMetaRef(uid).delete();
          sheet = await ensureDsrSheet(uid, token);
          first = await sheetsAppendRowsRaw(token, {
            spreadsheetId: sheet.spreadsheetId,
            tab: DSR_TAB,
            rows: unsynced.map((v) => visitToRow(v, timezone)),
          });
        } else {
          throw e;
        }
      }
      const batch = getFirestore().batch();
      unsynced.forEach((v, i) => {
        batch.update(visitsRef(uid).doc(v.id), {
          sheetRow: first != null ? first + i : -1,
          sheetFollowUpPending: false,
        });
      });
      await batch.commit();
      written += unsynced.length;
    }

    const stale = await visitsRef(uid).where("sheetFollowUpPending", "==", true).get();
    for (const doc of stale.docs) {
      const v = fromDoc(doc.id, doc.data());
      if (v.sheetRow != null && v.sheetRow > 0) {
        await sheetsUpdateRow(token, {
          spreadsheetId: sheet.spreadsheetId,
          tab: DSR_TAB,
          row: v.sheetRow,
          cells: visitToRow(v, timezone),
        });
        written++;
      }
      await doc.ref.update({ sheetFollowUpPending: false });
    }

    return { written, url: sheet.url || null, created: sheet.created, problem: null };
  } catch (e) {
    logger.warn("syncVisitsToSheet failed", { err: e instanceof Error ? e.message : String(e) });
    return {
      written: 0,
      url: await dsrSheetLink(uid).catch(() => null),
      created: false,
      problem:
        e instanceof GoogleApiError
          ? `the DSR sheet could not be updated — ${e.userMessage}`
          : "the DSR sheet could not be updated just now; it will catch up on the next save.",
    };
  }
}

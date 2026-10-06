/**
 * Deleting what the user asks to delete — after a card, and never for good.
 *
 * "Ye reminder delete karo", "Bajaj wala visit hata do": the tool finds the
 * one record meant (or asks which, when several match), draws a card saying
 * exactly what goes, and only the confirm deletes. The record is first copied
 * to `users/{uid}/trash/{id}` with its path, so "wapas lao" can put it back;
 * nothing is ever deleted without that copy written first.
 *
 * Deleting also tidies what hangs off the record: reminders tied to it are
 * cancelled (a deleted visit must not keep ringing for its follow-up), a
 * project's items go into the same trash entry, and a visit's or a day's
 * travel rows in the Google Sheets are blanked — blanked, not removed, because
 * every later record remembers its row number.
 */

import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";

import { cancelReminders } from "./reminderCancel";
import { sheetsUpdateRow } from "./google/workspace";
import { DSR_HEADER, DSR_TAB } from "./visitStore";
import { EXPENSE_HEADER, EXPENSE_TAB } from "./expenseStore";

export const DELETE_KINDS = [
  "reminder",
  "task",
  "project",
  "visit",
  "travel_expense",
  "saved_place",
  "occasion",
  "remembered_fact",
  "contact",
  "library_item",
  "quotation",
  "order",
  "payment_due",
  "client",
] as const;

export type DeleteKind = (typeof DELETE_KINDS)[number];

export function isDeleteKind(v: string): v is DeleteKind {
  return (DELETE_KINDS as readonly string[]).includes(v);
}

/** One record the card will delete. Everything commit needs, nothing it must look up again. */
export interface DeleteTarget {
  kind: DeleteKind;
  /** Full Firestore path of the document. */
  path: string;
  /** What the card says is going. */
  label: string;
  /** For remembered facts: the one key removed from `memory/profile`. */
  memoryKey?: string;
  /** Reminder ids to cancel with it. */
  reminderIds: string[];
  /** Reminders pointing at it by a field (`visitId`, `projectId`, …). */
  reminderLinks: Array<{ field: string; value: string }>;
  /** Sheet rows to blank: DSR for a visit, the expense sheet for a day. */
  sheetRows?: { sheet: "dsr" | "expense"; first: number; count: number };
}

type Doc = { id: string; path: string; data: Record<string, unknown> };

const s = (v: unknown) => (typeof v === "string" ? v : "");
const n = (v: unknown) => (typeof v === "number" ? v : 0);

function userDoc(uid: string) {
  return getFirestore().collection("users").doc(uid);
}

/** Every word of the query appears somewhere in the record. */
export function matchesQuery(fields: string[], query: string): boolean {
  const hay = fields.join(" ").toLowerCase();
  const words = query.toLowerCase().split(/\s+/).filter((w) => w.length > 0);
  return words.length > 0 && words.every((w) => hay.includes(w));
}

function dateText(ms: number, timezone: string): string {
  if (!ms) return "";
  return new Date(ms).toLocaleString("en-IN", {
    timeZone: timezone,
    day: "numeric",
    month: "short",
    hour: "numeric",
    minute: "2-digit",
  });
}

async function scan(
  uid: string,
  collection: string,
  opts: { order?: string; limit?: number } = {},
): Promise<Doc[]> {
  let q: FirebaseFirestore.Query = userDoc(uid).collection(collection);
  if (opts.order) q = q.orderBy(opts.order, "desc");
  const snap = await q.limit(opts.limit ?? 300).get();
  return snap.docs.map((d) => ({ id: d.id, path: d.ref.path, data: d.data() }));
}

/**
 * Finds what "delete X" means. Returns every match, newest first; the tool
 * decides between one card and "which one?".
 */
export async function findDeleteTargets(
  uid: string,
  kind: DeleteKind,
  query: string,
  opts: { id?: string; timezone: string; dayKey?: string | null; all?: boolean },
): Promise<DeleteTarget[]> {
  const tz = opts.timezone;
  // "Jo bhi orders hai sab delete karo": every record of the kind, no words.
  const everything = opts.all === true && !query.trim() && !opts.id;
  const byId = (docs: Doc[]) => (opts.id ? docs.filter((d) => d.id === opts.id) : null);
  const pick = (docs: Doc[], fields: (d: Doc) => string[]) =>
    byId(docs) ?? (everything ? docs : docs.filter((d) => matchesQuery(fields(d), query)));

  switch (kind) {
    case "reminder": {
      const docs = (await scan(uid, "reminders", { order: "scheduledTimeMs" })).filter(
        (d) => s(d.data.status) === "pending",
      );
      return pick(docs, (d) => [s(d.data.title), s(d.data.clientName), s(d.data.note)]).map((d) => ({
        kind,
        path: d.path,
        label: `${s(d.data.title)} — ${dateText(n(d.data.scheduledTimeMs), tz)}`,
        reminderIds: [d.id],
        reminderLinks: [{ field: "relatedReminderId", value: d.id }],
      }));
    }
    case "task":
    case "project": {
      const docs = (await scan(uid, "projects", { order: "updatedAtMs" })).filter((d) => {
        const isTask = s(d.data.kind) === "task";
        return kind === "task" ? isTask : !isTask;
      });
      return pick(docs, (d) => [s(d.data.name), s(d.data.clientName)]).map((d) => ({
        kind,
        path: d.path,
        label: [s(d.data.name), s(d.data.clientName)].filter(Boolean).join(" — "),
        reminderIds: Array.isArray(d.data.reminderIds) ? (d.data.reminderIds as string[]) : [],
        reminderLinks: [{ field: "projectId", value: d.id }],
      }));
    }
    case "visit": {
      const docs = await scan(uid, "visits", { order: "visitDateMs" });
      return pick(docs, (d) => [s(d.data.clientName), s(d.data.contactPerson), s(d.data.dateLabel), s(d.data.location)]).map(
        (d) => ({
          kind,
          path: d.path,
          label: `${s(d.data.clientName)} — ${s(d.data.dateLabel)}`,
          reminderIds: s(d.data.followUpReminderId) ? [s(d.data.followUpReminderId)] : [],
          reminderLinks: [{ field: "visitId", value: d.id }],
          ...(n(d.data.sheetRow) > 0 ? { sheetRows: { sheet: "dsr" as const, first: n(d.data.sheetRow), count: 1 } } : {}),
        }),
      );
    }
    case "travel_expense": {
      const docs = await scan(uid, "travelExpenses", { order: "dateMs" });
      const wanted = opts.id || opts.dayKey || "";
      const hits = wanted
        ? docs.filter((d) => d.id === wanted)
        : everything
          ? docs
          : docs.filter((d) => matchesQuery([s(d.data.dateLabel), d.id], query));
      return hits.map((d) => {
        const legs = Array.isArray(d.data.legs) ? d.data.legs.length : 0;
        return {
          kind,
          path: d.path,
          label: `Travel ${s(d.data.dateLabel)} — ${n(d.data.totalKm)} km, ₹${n(d.data.totalAmount)}`,
          reminderIds: [],
          reminderLinks: [],
          ...(n(d.data.sheetRow) > 0 && legs > 0
            ? { sheetRows: { sheet: "expense" as const, first: n(d.data.sheetRow), count: legs } }
            : {}),
        };
      });
    }
    case "saved_place":
    case "occasion":
    case "library_item": {
      const col = kind === "saved_place" ? "places" : kind === "occasion" ? "occasions" : "library";
      const docs = await scan(uid, col);
      return pick(docs, (d) => [s(d.data.name), s(d.data.title), s(d.data.address)]).map((d) => ({
        kind,
        path: d.path,
        label: s(d.data.name) || s(d.data.title),
        reminderIds: [],
        reminderLinks: [],
      }));
    }
    case "remembered_fact": {
      const snap = await userDoc(uid).collection("memory").doc("profile").get();
      const data = snap.data() ?? {};
      return Object.entries(data)
        .filter(([k, v]) => k !== "updatedAtMs" && typeof v === "string")
        .filter(([k, v]) =>
          opts.id ? k === opts.id : everything || matchesQuery([k.replace(/_/g, " "), v as string], query),
        )
        .map(([k, v]) => ({
          kind,
          path: snap.ref.path,
          label: `${k.replace(/_/g, " ")}: ${v as string}`,
          memoryKey: k,
          reminderIds: [],
          reminderLinks: [],
        }));
    }
    case "contact": {
      const snap = await getFirestore().collection("contacts").where("ownerUid", "==", uid).limit(500).get();
      const docs = snap.docs.map((d) => ({ id: d.id, path: d.ref.path, data: d.data() }));
      return pick(docs, (d) => [s(d.data.name), s(d.data.company), s(d.data.phone), s(d.data.email)]).map((d) => ({
        kind,
        path: d.path,
        label: [s(d.data.name), s(d.data.company), s(d.data.phone)].filter(Boolean).join(" · "),
        reminderIds: [],
        reminderLinks: [],
      }));
    }
    case "client": {
      // Only the client's own entry goes. Quotations, orders, dues and visits
      // keep the client's name on them and stay until deleted themselves —
      // the card says how many there are.
      const docs = await scan(uid, "clients");
      const hits = pick(docs, (d) => [s(d.data.name)]);
      const linked = async (id: string) => {
        let total = 0;
        for (const col of ["quotations", "orders", "payments", "visits"]) {
          const snap = await userDoc(uid).collection(col).where("clientId", "==", id).limit(100).get();
          total += snap.docs.length;
        }
        return total;
      };
      const out: DeleteTarget[] = [];
      for (const d of hits.slice(0, 50)) {
        const n = await linked(d.id).catch(() => 0);
        out.push({
          kind,
          path: d.path,
          label: n > 0 ? `${s(d.data.name)} (${n} linked record${n === 1 ? "" : "s"} stay)` : s(d.data.name),
          reminderIds: [],
          reminderLinks: [],
        });
      }
      return out;
    }
    case "quotation":
    case "order":
    case "payment_due": {
      const col = kind === "quotation" ? "quotations" : kind === "order" ? "orders" : "payments";
      let docs = await scan(uid, col, { order: "createdAtMs" });
      if (kind === "payment_due") {
        // Money already received is the ledger; only a due nothing was paid
        // against can go.
        docs = docs.filter((d) => n(d.data.paidAmount) === 0 && n(d.data.remainingAmount) > 0);
      }
      return pick(docs, (d) => [s(d.data.clientName), String(n(d.data.amount)), s(d.data.note), s(d.data.status)]).map(
        (d) => ({
          kind,
          path: d.path,
          label: `${s(d.data.clientName)} — ₹${n(d.data.amount)} (${dateText(n(d.data.createdAtMs), tz)})`,
          reminderIds: [],
          reminderLinks: [{ field: kind === "quotation" ? "quotationId" : kind === "order" ? "orderId" : "paymentId", value: d.id }],
        }),
      );
    }
  }
}

async function linkedReminderIds(uid: string, links: DeleteTarget["reminderLinks"]): Promise<string[]> {
  const out: string[] = [];
  for (const l of links) {
    const snap = await userDoc(uid).collection("reminders").where(l.field, "==", l.value).limit(50).get();
    snap.docs.forEach((d) => out.push(d.id));
  }
  return out;
}

async function blankSheetRows(uid: string, token: string, rows: NonNullable<DeleteTarget["sheetRows"]>): Promise<void> {
  const meta = await userDoc(uid).collection("meta").doc(rows.sheet === "dsr" ? "dsr" : "expenseSheet").get();
  const spreadsheetId = s(meta.data()?.spreadsheetId);
  if (!spreadsheetId) return;
  const width = rows.sheet === "dsr" ? DSR_HEADER.length : EXPENSE_HEADER.length;
  const tab = rows.sheet === "dsr" ? DSR_TAB : EXPENSE_TAB;
  for (let r = rows.first; r < rows.first + rows.count; r++) {
    await sheetsUpdateRow(token, { spreadsheetId, tab, row: r, cells: new Array<string>(width).fill("") });
  }
}

export interface DeleteOutcome {
  trashId: string;
  remindersCancelled: number;
  sheetCleared: boolean | null;
}

/** Copies to trash, then deletes, then tidies. The copy is written first, always. */
export async function deleteTarget(
  uid: string,
  t: DeleteTarget,
  opts: { googleToken?: string | null } = {},
): Promise<DeleteOutcome> {
  const db = getFirestore();
  const ref = db.doc(t.path);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new Error(`already gone: ${t.label}`);
  }
  const data = snap.data() ?? {};
  // Root contacts carry their owner; anything under users/ is the user's by path.
  if (t.path.startsWith("contacts/") && s(data.ownerUid) !== uid) {
    throw new Error("not this user's contact");
  }
  if (!t.path.startsWith("contacts/") && !t.path.startsWith(`users/${uid}/`)) {
    throw new Error("not this user's record");
  }

  let items: Array<{ id: string; data: Record<string, unknown> }> = [];
  if (t.kind === "task" || t.kind === "project") {
    const itemSnap = await ref.collection("items").get();
    items = itemSnap.docs.map((d) => ({ id: d.id, data: d.data() }));
    items.forEach((i) => {
      const rid = s(i.data.reminderId);
      if (rid) t.reminderIds.push(rid);
    });
  }

  const trashRef = userDoc(uid).collection("trash").doc();
  await trashRef.set({
    kind: t.kind,
    label: t.label,
    path: t.path,
    deletedAtMs: Date.now(),
    restored: false,
    ...(t.memoryKey
      ? { memoryKey: t.memoryKey, data: { [t.memoryKey]: data[t.memoryKey] ?? null } }
      : { data }),
    ...(items.length > 0 ? { items } : {}),
  });

  if (t.memoryKey) {
    await ref.update({ [t.memoryKey]: FieldValue.delete(), updatedAtMs: Date.now() });
  } else {
    for (const i of items) {
      await ref.collection("items").doc(i.id).delete();
    }
    await ref.delete();
  }

  const ids = [...t.reminderIds, ...(await linkedReminderIds(uid, t.reminderLinks).catch(() => []))];
  // A deleted reminder is itself cancelled first, so the phone's alarm sync
  // sees it leave the pending set even if it reads before the delete lands.
  const cancelled = await cancelReminders(uid, ids.filter((id) => !t.path.endsWith(`/reminders/${id}`)));

  let sheetCleared: boolean | null = null;
  if (t.sheetRows) {
    if (opts.googleToken) {
      try {
        await blankSheetRows(uid, opts.googleToken, t.sheetRows);
        sheetCleared = true;
      } catch (e) {
        logger.warn("delete: sheet rows not blanked", { err: e instanceof Error ? e.message : String(e) });
        sheetCleared = false;
      }
    } else {
      sheetCleared = false;
    }
  }
  return { trashId: trashRef.id, remindersCancelled: cancelled, sheetCleared };
}

/** The latest things deleted, for "wapas lao". */
export async function listTrash(uid: string, limit = 10): Promise<Array<{ id: string; kind: string; label: string; deletedAtMs: number; restored: boolean }>> {
  const snap = await userDoc(uid).collection("trash").orderBy("deletedAtMs", "desc").limit(limit).get();
  return snap.docs.map((d) => ({
    id: d.id,
    kind: s(d.data().kind),
    label: s(d.data().label),
    deletedAtMs: n(d.data().deletedAtMs),
    restored: d.data().restored === true,
  }));
}

/** Puts a trashed record back where it was. Reminders cancelled with it stay cancelled. */
export async function restoreFromTrash(uid: string, trashId: string): Promise<{ kind: string; label: string }> {
  const db = getFirestore();
  const tref = userDoc(uid).collection("trash").doc(trashId);
  const snap = await tref.get();
  if (!snap.exists) throw new Error("not in trash");
  const t = snap.data() ?? {};
  if (t.restored === true) throw new Error("already restored");
  const path = s(t.path);
  if (!path.startsWith(`users/${uid}/`) && !path.startsWith("contacts/")) throw new Error("bad path");
  const data = { ...((t.data ?? {}) as Record<string, unknown>) };
  // The sheet rows were blanked on delete: a visit rewrites its own row on
  // the next sync, a day of travel is appended again.
  if (path.includes("/visits/")) data.sheetFollowUpPending = true;
  if (path.includes("/travelExpenses/")) data.sheetRow = null;
  const ref = db.doc(path);
  if (typeof t.memoryKey === "string") {
    await ref.set(data, { merge: true });
  } else {
    await ref.set(data);
    const items = Array.isArray(t.items) ? (t.items as Array<{ id: string; data: Record<string, unknown> }>) : [];
    for (const i of items) {
      await ref.collection("items").doc(i.id).set(i.data);
    }
  }
  await tref.update({ restored: true, restoredAtMs: Date.now() });
  return { kind: s(t.kind), label: s(t.label) };
}

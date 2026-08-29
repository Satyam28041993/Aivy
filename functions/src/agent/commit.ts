/**
 * Turns a confirmed draft into real records.
 *
 * Every document written here matches, field for field, what the app's own
 * repositories write. That is not cosmetic: the 21 existing analytics queries
 * filter on `createdAtMs`, `clientNameLower`, `status`, `remainingAmount` and
 * friends, so a near-miss shape would save fine and then be invisible to every
 * report. The shapes are mirrored from:
 *
 *   - reminders  → `lib/features/reminders/data/reminder_repository.dart:24-61`
 *   - quotations → `lib/features/chat/data/chat_repository.dart:150-185`
 *   - orders     → `lib/features/chat/data/chat_repository.dart:121-148`
 *   - payments   → `lib/features/payments/data/payment_repository.dart:295-335`
 *
 * Reminders written here still get notified: `checkReminders` is a scheduled
 * function over `collectionGroup("reminders")` keyed on `scheduledTimeMs`, so
 * it picks up server-written rows exactly like app-written ones.
 */

import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { DateTime } from "luxon";

import { createClient } from "./clientResolve";
import { getDraft, markDraftStatus } from "./draftStore";
import { normalizeName } from "./nameNormalize";
import {
  effectiveRemainingAmount,
  effectivePaidAmount,
  effectiveOriginalAmount,
} from "../paymentSettlement";
import {
  calendarInsertEvent,
  gmailSend,
  GoogleApiError,
  sheetsAppendRow,
} from "./google/workspace";
import type {
  AgentDraft,
  CalendarEventDraftData,
  DraftClientRef,
  EmailDraftData,
  MeetingDraftData,
  OrderDraftData,
  PaymentDueDraftData,
  PaymentReceivedDraftData,
  QuotationDraftData,
  ReminderDraftData,
  RememberFactDraftData,
  SheetRowDraftData,
} from "./draftTypes";

/**
 * Extras a commit may need beyond the draft itself. The Google token is the
 * only one so far: it cannot be stored with the draft (a token in Firestore is
 * a token waiting to leak), so the client resends it when confirming.
 */
export interface CommitOptions {
  googleToken?: string | null;
}

export interface CommitResult {
  ok: boolean;
  message: string;
  /** Ids of everything created, so the next turn can refer back to it. */
  createdIds: string[];
  /** Short description for the agent's memory of "what I just saved". */
  summary: string;
}

function userRef(uid: string) {
  return getFirestore().collection("users").doc(uid);
}

/** Creates the client if the draft said it was new, and returns id + name. */
async function ensureClient(
  uid: string,
  ref: DraftClientRef,
): Promise<{ id: string; name: string }> {
  if (!ref.createNew && ref.id) {
    return { id: ref.id, name: ref.name };
  }
  const created = await createClient(uid, ref.name);
  return { id: created.id, name: created.name };
}

/**
 * Writes a reminder in the exact shape `ReminderRepository.createReminder` uses.
 * `scheduledTimeMs` is what `checkReminders` scans, so it must be present.
 */
async function writeReminder(
  uid: string,
  opts: {
    title: string;
    scheduledMs: number;
    type: string;
    subType: string;
    note?: string | null;
    clientName?: string | null;
    priority?: string | null;
    extra?: Record<string, unknown>;
  },
): Promise<string> {
  const ref = userRef(uid).collection("reminders").doc();
  const createdMs = Date.now();
  const data: Record<string, unknown> = {
    title: opts.title.trim(),
    scheduledAt: DateTime.fromMillis(opts.scheduledMs).toJSDate(),
    scheduledTimeMs: opts.scheduledMs,
    type: opts.type.trim().toLowerCase(),
    subType: opts.subType.trim(),
    status: "pending",
    createdAt: FieldValue.serverTimestamp(),
    createdAtMs: createdMs,
  };
  if (opts.note && opts.note.trim()) {
    data.note = opts.note.trim();
  }
  if (opts.clientName && opts.clientName.trim()) {
    data.clientName = opts.clientName.trim();
  }
  if (opts.priority && opts.priority.trim()) {
    data.priority = opts.priority.trim().toLowerCase();
  }
  if (opts.extra) {
    Object.assign(data, opts.extra);
  }
  await ref.set(data);
  return ref.id;
}

async function commitMeeting(
  uid: string,
  d: MeetingDraftData,
  opts: CommitOptions,
): Promise<CommitResult> {
  const client = d.client ? await ensureClient(uid, d.client) : null;
  const who = client ? ` — ${client.name}` : "";
  const title = d.agenda ? `Meeting: ${d.agenda}` : `Meeting${who}`;

  const meetingId = await writeReminder(uid, {
    title,
    scheduledMs: d.whenMs,
    type: "meeting",
    subType: "meeting",
    note: d.agenda || d.note,
    clientName: client?.name ?? null,
    priority: "high",
    extra: { agenda: d.agenda || null, isMeeting: true },
  });

  const ids = [meetingId];
  // The nudge before the meeting is a separate row so it fires on its own.
  const leadMs = d.whenMs - d.reminderLeadMinutes * 60 * 1000;
  if (d.reminderLeadMinutes > 0 && leadMs > Date.now()) {
    const nudgeId = await writeReminder(uid, {
      title: `Meeting ${d.reminderLeadMinutes} min me${who}`,
      scheduledMs: leadMs,
      type: "reminder",
      subType: "meeting_reminder",
      note: d.agenda || null,
      clientName: client?.name ?? null,
      priority: "high",
      extra: { relatedReminderId: meetingId },
    });
    ids.push(nudgeId);
  }

  // Google Calendar is best-effort on purpose: the meeting is already saved in
  // the app by this point, and losing it because Google returned a 403 would be
  // the wrong trade. The message says what happened either way.
  let calendarNote = "";
  if (d.addToCalendar && opts.googleToken) {
    try {
      await calendarInsertEvent(opts.googleToken, {
        summary: title,
        description: d.note ?? null,
        startMs: d.whenMs,
        durationMinutes: d.durationMinutes ?? 60,
        timezone: "UTC",
      });
      calendarNote = " Google Calendar par bhi daal diya.";
    } catch (e) {
      calendarNote =
        e instanceof GoogleApiError && e.isAuth
          ? " (Calendar par nahi daal paayi — Google permission chahiye.)"
          : " (Calendar par nahi daal paayi.)";
    }
  }

  return {
    ok: true,
    message: `Meeting set ho gayi — ${d.whenLabel}${who}.${calendarNote}`,
    createdIds: ids,
    summary: `meeting ${client?.name ?? ""} ${d.whenLabel} (${d.agenda || "no agenda"})`.trim(),
  };
}

async function commitReminder(uid: string, d: ReminderDraftData): Promise<CommitResult> {
  const client = d.client ? await ensureClient(uid, d.client) : null;
  const id = await writeReminder(uid, {
    title: d.title,
    scheduledMs: d.whenMs,
    type: d.reminderType === "call" || d.reminderType === "followup" ? d.reminderType : "reminder",
    subType: d.reminderType,
    note: d.note,
    clientName: client?.name ?? null,
    priority: d.priority,
  });
  return {
    ok: true,
    message: `Reminder lag gaya — ${d.whenLabel}.`,
    createdIds: [id],
    summary: `reminder "${d.title}" ${d.whenLabel}`,
  };
}

async function commitQuotation(uid: string, d: QuotationDraftData): Promise<CommitResult> {
  const client = await ensureClient(uid, d.client);
  const nowMs = Date.now();
  const ref = userRef(uid).collection("quotations").doc();
  await ref.set({
    clientName: client.name,
    clientNameLower: normalizeName(client.name),
    amount: d.amount,
    followUpDateMs: d.followUpMs,
    status: "pending",
    ...(d.note ? { note: d.note } : {}),
    createdAt: FieldValue.serverTimestamp(),
    createdAtMs: nowMs,
    updatedAt: FieldValue.serverTimestamp(),
    updatedAtMs: nowMs,
  });

  const reminderId = await writeReminder(uid, {
    title: `Quotation follow-up: ${client.name}`,
    scheduledMs: d.followUpMs,
    type: "followup",
    subType: "quotation_followup",
    note: d.note ?? `Quotation ${d.amount}`,
    clientName: client.name,
    extra: { quotationId: ref.id, amount: d.amount },
  });

  return {
    ok: true,
    message: `Quotation record ho gaya — ${client.name}, follow-up ${d.followUpLabel}.`,
    createdIds: [ref.id, reminderId],
    summary: `quotation ${client.name} ${d.amount}`,
  };
}

async function commitOrder(uid: string, d: OrderDraftData): Promise<CommitResult> {
  const client = await ensureClient(uid, d.client);
  const nowMs = Date.now();
  const ref = userRef(uid).collection("orders").doc();
  await ref.set({
    clientName: client.name,
    clientNameLower: normalizeName(client.name),
    amount: d.amount,
    status: "pending",
    ...(d.note ? { note: d.note } : {}),
    createdAt: FieldValue.serverTimestamp(),
    createdAtMs: nowMs,
    updatedAt: FieldValue.serverTimestamp(),
    updatedAtMs: nowMs,
  });
  return {
    ok: true,
    message: `Order record ho gaya — ${client.name}.`,
    createdIds: [ref.id],
    summary: `order ${client.name} ${d.amount}`,
  };
}

async function commitPaymentDue(uid: string, d: PaymentDueDraftData): Promise<CommitResult> {
  const client = await ensureClient(uid, d.client);
  const nowMs = Date.now();
  const dueDay = DateTime.fromMillis(d.dueMs).startOf("day");
  const today = DateTime.fromMillis(nowMs).startOf("day");
  const overdue = dueDay < today;

  const ref = userRef(uid).collection("payments").doc();
  await ref.set({
    type: "payment_due",
    subType: "payment_due",
    clientId: client.id,
    clientName: client.name,
    clientNameLower: normalizeName(client.name),
    amount: d.amount,
    paymentVersion: 2,
    originalAmount: d.amount,
    paidAmount: 0,
    remainingAmount: d.amount,
    receiptCount: 0,
    status: overdue ? "overdue" : "pending",
    dueDateMs: d.dueMs,
    dueDate: DateTime.fromMillis(d.dueMs).toJSDate(),
    ...(d.note ? { note: d.note } : {}),
    createdAt: FieldValue.serverTimestamp(),
    createdAtMs: nowMs,
    updatedAt: FieldValue.serverTimestamp(),
    updatedAtMs: nowMs,
  });

  return {
    ok: true,
    message: `Due record ho gaya — ${client.name}, ${d.dueLabel}.`,
    createdIds: [ref.id],
    summary: `payment due ${client.name} ${d.amount}`,
  };
}

/**
 * Applies a receipt across the client's open dues, oldest first, and writes a
 * receipt row. Uses a transaction so two quick confirms cannot double-settle.
 */
async function commitPaymentReceived(
  uid: string,
  d: PaymentReceivedDraftData,
): Promise<CommitResult> {
  const db = getFirestore();
  const client = await ensureClient(uid, d.client);
  const nowMs = Date.now();
  const paymentsCol = userRef(uid).collection("payments");
  const receiptRef = paymentsCol.doc();

  const touched: string[] = [];
  let applied = 0;

  await db.runTransaction(async (tx) => {
    let left = d.amount;
    const snaps = [];
    for (const target of d.targets) {
      const ref = paymentsCol.doc(target.paymentId);
      snaps.push({ ref, snap: await tx.get(ref) });
    }

    for (const { ref, snap } of snaps) {
      if (left <= 0 || !snap.exists) {
        continue;
      }
      const data = snap.data()!;
      const remaining = effectiveRemainingAmount(data);
      if (remaining <= 0) {
        continue;
      }
      const take = Math.min(remaining, left);
      const paid = effectivePaidAmount(data) + take;
      const original = effectiveOriginalAmount(data);
      const nowRemaining = Math.max(0, original - paid);
      const receipts = Number(data.receiptCount ?? 0) + 1;

      tx.update(ref, {
        paidAmount: paid,
        remainingAmount: nowRemaining,
        receiptCount: receipts,
        paymentVersion: 2,
        status: nowRemaining <= 0.01 ? "paid" : data.status ?? "pending",
        updatedAt: FieldValue.serverTimestamp(),
        updatedAtMs: nowMs,
      });
      touched.push(ref.id);
      left -= take;
      applied += take;
    }

    tx.set(receiptRef, {
      type: "payment_receipt",
      subType: "payment_received",
      clientId: client.id,
      clientName: client.name,
      clientNameLower: normalizeName(client.name),
      amount: d.amount,
      paymentVersion: 2,
      status: "received",
      receivedAtMs: d.receivedMs,
      receivedAt: DateTime.fromMillis(d.receivedMs).toJSDate(),
      settledPaymentIds: touched,
      unappliedAmount: Math.max(0, left),
      ...(d.note ? { note: d.note } : {}),
      createdAt: FieldValue.serverTimestamp(),
      createdAtMs: nowMs,
      updatedAt: FieldValue.serverTimestamp(),
      updatedAtMs: nowMs,
    });
  });

  const leftover = d.amount - applied;
  const extra = leftover > 0.01 ? ` (${leftover} advance rakha)` : "";
  return {
    ok: true,
    message: `Payment receive ho gaya — ${client.name}${extra}.`,
    createdIds: [receiptRef.id, ...touched],
    summary: `payment received ${client.name} ${d.amount}`,
  };
}

/**
 * Writes into `users/{uid}/memory/profile` — the same document `getUserMemory`
 * reads, so the next turn's system prompt carries it.
 *
 * It does NOT go through `saveUserMemory`: that helper is a deliberate no-op
 * for the old chat pipeline ("no server-side memory writes"), which meant this
 * tool answered "yaad rakh liya" and then remembered nothing. A confirmed card
 * must actually save.
 */
async function commitRememberFact(
  uid: string,
  d: RememberFactDraftData,
): Promise<CommitResult> {
  await userRef(uid)
    .collection("memory")
    .doc("profile")
    .set(
      { [d.category]: d.fact, updatedAtMs: Date.now() },
      { merge: true },
    );
  return {
    ok: true,
    message: "Yaad rakh liya.",
    createdIds: [],
    summary: `remembered: ${d.fact}`,
  };
}

// ---------------------------------------------------------------------------
// Google Workspace
// ---------------------------------------------------------------------------

/**
 * These three actually leave the building — an event on someone's calendar, a
 * mail in someone's inbox, a row in a shared sheet. Unlike the Firestore
 * writes above there is no undo, which is exactly why they only run here, after
 * the user has read the card and tapped confirm.
 */

function needsGoogle(): CommitResult {
  return {
    ok: false,
    message:
      "Google connect nahi hai — Android app me More → Allow Google extras se permission dijiye.",
    createdIds: [],
    summary: "",
  };
}

function googleFailed(e: unknown, what: string): CommitResult {
  const message =
    e instanceof GoogleApiError
      ? `${what} nahi ho paaya — ${e.hindiMessage}`
      : `${what} nahi ho paaya.`;
  return { ok: false, message, createdIds: [], summary: "" };
}

async function commitCalendarEvent(
  d: CalendarEventDraftData,
  opts: CommitOptions,
): Promise<CommitResult> {
  if (!opts.googleToken) {
    return needsGoogle();
  }
  try {
    const ref = await calendarInsertEvent(opts.googleToken, {
      summary: d.summary,
      description: d.description,
      startMs: d.whenMs,
      durationMinutes: d.durationMinutes,
      timezone: d.timezone,
      attendeeEmails: d.attendeeEmails,
    });
    return {
      ok: true,
      message: `Calendar par daal diya — ${d.whenLabel}.`,
      createdIds: ref.id ? [ref.id] : [],
      summary: `calendar event "${d.summary}" ${d.whenLabel}`,
    };
  } catch (e) {
    return googleFailed(e, "Calendar event");
  }
}

async function commitEmail(
  d: EmailDraftData,
  opts: CommitOptions,
): Promise<CommitResult> {
  if (!opts.googleToken) {
    return needsGoogle();
  }
  try {
    const id = await gmailSend(opts.googleToken, {
      to: d.to,
      subject: d.subject,
      body: d.body,
    });
    const who = d.toName ? `${d.toName} ko` : `${d.to} par`;
    return {
      ok: true,
      message: `Mail bhej diya — ${who}.`,
      createdIds: id ? [id] : [],
      summary: `email to ${d.toName ?? d.to}: ${d.subject}`,
    };
  } catch (e) {
    return googleFailed(e, "Mail");
  }
}

async function commitSheetRow(
  uid: string,
  d: SheetRowDraftData,
  opts: CommitOptions,
): Promise<CommitResult> {
  if (!opts.googleToken) {
    return needsGoogle();
  }
  let spreadsheetId = d.spreadsheetId;
  if (!spreadsheetId) {
    const snap = await userRef(uid).collection("meta").doc("google_prefs").get();
    spreadsheetId = `${snap.data()?.defaultSpreadsheetId ?? ""}`.trim() || null;
  }
  if (!spreadsheetId) {
    return {
      ok: false,
      message: "Koi default Google Sheet set nahi hai.",
      createdIds: [],
      summary: "",
    };
  }
  try {
    await sheetsAppendRow(opts.googleToken, {
      spreadsheetId,
      tab: d.tab,
      cells: d.cells,
    });
    return {
      ok: true,
      message: "Sheet me row add kar di.",
      createdIds: [],
      summary: `sheet row: ${d.cells.join(" | ")}`,
    };
  } catch (e) {
    return googleFailed(e, "Sheet update");
  }
}

/** Replays one confirmed draft. Idempotent: a committed draft is not redone. */
export async function commitDraft(
  uid: string,
  draftId: string,
  opts: CommitOptions = {},
): Promise<CommitResult> {
  const draft: AgentDraft | null = await getDraft(uid, draftId);
  if (!draft) {
    return { ok: false, message: "Draft nahi mila.", createdIds: [], summary: "" };
  }
  if (draft.status === "committed") {
    return {
      ok: true,
      message: "Ye pehle hi save ho chuka hai.",
      createdIds: draft.resultIds ?? [],
      summary: "",
    };
  }
  if (draft.status === "cancelled") {
    return { ok: false, message: "Ye draft cancel ho chuka hai.", createdIds: [], summary: "" };
  }

  let result: CommitResult;
  switch (draft.data.kind) {
    case "meeting":
      result = await commitMeeting(uid, draft.data, opts);
      break;
    case "reminder":
      result = await commitReminder(uid, draft.data);
      break;
    case "quotation":
      result = await commitQuotation(uid, draft.data);
      break;
    case "order":
      result = await commitOrder(uid, draft.data);
      break;
    case "payment_due":
      result = await commitPaymentDue(uid, draft.data);
      break;
    case "payment_received":
      result = await commitPaymentReceived(uid, draft.data);
      break;
    case "remember_fact":
      result = await commitRememberFact(uid, draft.data);
      break;
    case "calendar_event":
      result = await commitCalendarEvent(draft.data, opts);
      break;
    case "email":
      result = await commitEmail(draft.data, opts);
      break;
    case "sheet_row":
      result = await commitSheetRow(uid, draft.data, opts);
      break;
    default:
      return { ok: false, message: "Is draft ka type samajh nahi aaya.", createdIds: [], summary: "" };
  }

  if (result.ok) {
    await markDraftStatus(uid, draftId, "committed", result.createdIds);
  }
  return result;
}

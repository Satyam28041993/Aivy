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
import { logger } from "firebase-functions";
import { DateTime } from "luxon";

import { createClient } from "./clientResolve";
import { addItems, createProject, setProjectReminders } from "./projectStore";
import { logProjectEvent } from "./projectEvents";
import { getDraft, markDraftStatus } from "./draftStore";
import { savePlace } from "./placesStore";
import { saveVisit, setVisitFollowUp, syncVisitsToSheet } from "./visitStore";
import { dayKey, expensePromptId, getExpense, saveExpense, syncExpensesToSheet } from "./expenseStore";
import { cancelReminders } from "./reminderCancel";
import { saveContact } from "./contactStore";
import { saveLibraryItem } from "./libraryStore";
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
  ProjectItemsDraftData,
  TaskDraftData,
  SavedPlaceDraftData,
  SavedContactDraftData,
  LibraryItemDraftData,
  SheetRowDraftData,
  VisitDraftData,
  VisitFollowupDraftData,
  TravelExpenseDraftData,
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
    /** A fixed id, for a reminder there must only ever be one of. */
    id?: string;
  },
): Promise<string> {
  const ref = opts.id
    ? userRef(uid).collection("reminders").doc(opts.id)
    : userRef(uid).collection("reminders").doc();
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
      calendarNote = " Added to Google Calendar too.";
    } catch (e) {
      calendarNote =
        e instanceof GoogleApiError && e.isAuth
          ? " (Could not add to Calendar — Google permission needed.)"
          : " (Could not add to Calendar.)";
    }
  }

  return {
    ok: true,
    message: `Meeting set — ${d.whenLabel}${who}.${calendarNote}`,
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
    message: `Reminder set — ${d.whenLabel}.`,
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
    message: `Quotation recorded — ${client.name}, follow-up ${d.followUpLabel}.`,
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
    message: `Order recorded — ${client.name}.`,
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
    message: `Due recorded — ${client.name}, due ${d.dueLabel}.`,
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
    message: `Payment recorded — ${client.name}${extra}.`,
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
  // Each fact lands on its own key, so a second family detail sits beside the
  // first instead of replacing it. Drafts written before this carry only
  // category/fact, and still commit.
  const facts =
    d.facts && d.facts.length > 0
      ? d.facts
      : [{ key: d.category, value: d.fact }];

  const patch: Record<string, unknown> = { updatedAtMs: Date.now() };
  for (const f of facts) {
    if (f.key && f.value) {
      patch[f.key] = f.value;
    }
  }

  await userRef(uid).collection("memory").doc("profile").set(patch, { merge: true });

  return {
    ok: true,
    message:
      facts.length === 1
        ? "Got it, I'll remember that."
        : `Got it — ${facts.length} things remembered.`,
    createdIds: [],
    summary: `remembered: ${facts.map((f) => f.value).join("; ")}`,
  };
}

/**
 * Project items, and a reminder for each one that carries a date.
 *
 * The reminder is the point. A tracker nobody is reminded about is a list that
 * goes stale in a week; routing dated items through the same reminders the rest
 * of the app uses means they ring on the phone like everything else, with no
 * second mechanism to build or keep working.
 */
async function commitProjectItems(
  uid: string,
  d: ProjectItemsDraftData,
): Promise<CommitResult> {
  const withReminders: Array<Parameters<typeof addItems>[2][number]> = [];

  for (const line of d.items) {
    let reminderId = "";
    if (line.dueMs > 0 && line.status !== "done") {
      try {
        reminderId = await writeReminder(uid, {
          title: line.title,
          scheduledMs: line.dueMs,
          type: line.kind === "meeting" ? "meeting" : "reminder",
          subType: `project_${line.kind}`,
          note: d.projectName,
          extra: { projectId: d.projectId, projectName: d.projectName },
        });
      } catch (e) {
        // An item without its alarm is still an item; losing the whole save
        // because one reminder failed would be the worse trade.
        logger.warn("commitProjectItems: reminder failed", {
          err: e instanceof Error ? e.message : String(e),
        });
      }
    }
    withReminders.push({
      title: line.title,
      kind: line.kind as never,
      status: line.status as never,
      dueMs: line.dueMs,
      note: line.note,
      reminderId,
    });
  }

  const saved = await addItems(uid, d.projectId, withReminders);
  const dated = saved.filter((i) => i.reminderId).length;

  await logProjectEvent(
    uid,
    d.projectId,
    "items_added",
    `Added ${saved.length} item(s): ${saved.map((i) => i.title).join(", ")}`,
  );

  return {
    ok: true,
    message:
      dated > 0
        ? `Added to ${d.projectName} — ${saved.length} item(s), ${dated} with a reminder.`
        : `Added to ${d.projectName} — ${saved.length} item(s).`,
    createdIds: saved.map((i) => i.id),
    summary: `${d.projectName}: ${saved.map((i) => i.title).join("; ")}`,
  };
}

/**
 * A task, its steps and its reminders, written together.
 *
 * The order matters on failure. The task doc goes first, because a task with no
 * alarm is still a task he can be told about, while an alarm pointing at
 * nothing is a notification he cannot act on. Reminders are best-effort for the
 * same reason items' reminders are: losing the whole save because a write to
 * one collection failed would be the worse trade by a distance.
 */
async function commitTask(uid: string, d: TaskDraftData): Promise<CommitResult> {
  const project = await createProject(uid, {
    name: d.name,
    clientName: d.forWhom || null,
    note: d.note || null,
    kind: "task",
    area: d.area,
    dueMs: d.dueMs,
  });

  const steps = d.steps.length > 0 ? await addItems(uid, project.id, d.steps.map((st) => ({
    title: st.title,
    kind: (st.kind || "task") as never,
    status: (st.status || "open") as never,
    dueMs: 0,
    note: st.note,
  }))) : [];

  const forWhom = d.forWhom.trim();
  const reminderIds: string[] = [];

  if (d.dueMs > Date.now()) {
    try {
      reminderIds.push(
        await writeReminder(uid, {
          title: d.name,
          scheduledMs: d.dueMs,
          type: "reminder",
          subType: "task_due",
          note: forWhom ? `Due now — for ${forWhom}` : "Due now",
          clientName: forWhom || null,
          priority: "high",
          extra: { projectId: project.id, projectName: project.name, isTask: true },
        }),
      );
    } catch (e) {
      logger.warn("commitTask: deadline reminder failed", {
        err: e instanceof Error ? e.message : String(e),
      });
    }
  }

  if (d.nudgeMs > Date.now() && d.nudgeMs < d.dueMs) {
    try {
      reminderIds.push(
        await writeReminder(uid, {
          title: d.name,
          scheduledMs: d.nudgeMs,
          type: "reminder",
          subType: "task_nudge",
          note: d.dueLabel ? `Due ${d.dueLabel} — how much is done?` : "How much is done?",
          clientName: forWhom || null,
          extra: { projectId: project.id, projectName: project.name, isTask: true },
        }),
      );
    } catch (e) {
      logger.warn("commitTask: nudge reminder failed", {
        err: e instanceof Error ? e.message : String(e),
      });
    }
  }

  if (reminderIds.length > 0) {
    try {
      await setProjectReminders(uid, project.id, reminderIds);
    } catch (e) {
      // Only costs the ability to cancel them on close, which is worth a log
      // and not worth failing the save for.
      logger.warn("commitTask: could not attach reminders", {
        err: e instanceof Error ? e.message : String(e),
      });
    }
  }

  const opened = [
    "Task created",
    forWhom ? `for ${forWhom}` : "",
    d.dueLabel ? `due ${d.dueLabel}` : "no deadline",
    steps.length > 0 ? `${steps.length} step(s): ${steps.map((i) => i.title).join(", ")}` : "",
  ].filter(Boolean);
  await logProjectEvent(uid, project.id, "created", opened.join(" · "));

  const parts = [`Task saved — ${project.name}`];
  if (steps.length > 0) {
    parts.push(`${steps.length} step${steps.length === 1 ? "" : "s"}`);
  }
  parts.push(
    reminderIds.length === 0
      ? "no reminder, since it has no date"
      : reminderIds.length === 1
        ? "reminder set"
        : "reminder set, plus a check-in on the way",
  );

  return {
    ok: true,
    message: `${parts.join(", ")}.`,
    createdIds: [project.id, ...steps.map((i) => i.id)],
    summary: `task ${project.name}${forWhom ? ` for ${forWhom}` : ""}`,
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
      "Google is not connected — grant permission from More → Allow Google extras in the Android app.",
    createdIds: [],
    summary: "",
  };
}

function googleFailed(e: unknown, what: string): CommitResult {
  const message =
    e instanceof GoogleApiError
      ? `${what} failed — ${e.userMessage}`
      : `${what} failed.`;
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
      message: `Added to Calendar — ${d.whenLabel}.`,
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
    const who = d.toName ? d.toName : d.to;
    return {
      ok: true,
      message: `Email sent — ${who}.`,
      createdIds: id ? [id] : [],
      summary: `email to ${d.toName ?? d.to}: ${d.subject}`,
    };
  } catch (e) {
    return googleFailed(e, "Email");
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
      message: "No default Google Sheet is set.",
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
      message: "Row added to the sheet.",
      createdIds: [],
      summary: `sheet row: ${d.cells.join(" | ")}`,
    };
  } catch (e) {
    return googleFailed(e, "Sheet update");
  }
}

async function commitSavedPlace(
  uid: string,
  d: SavedPlaceDraftData,
): Promise<CommitResult> {
  const place = await savePlace(uid, {
    name: d.name,
    lat: d.lat,
    lng: d.lng,
    address: d.address,
  });
  const where = place.address ? ` — ${place.address}` : "";
  return {
    ok: true,
    message: `Saved "${place.name}"${where}. Ask me anytime and I'll send the link.`,
    createdIds: [place.id],
    summary: `saved place ${place.name}`,
  };
}

// ---------------------------------------------------------------------------
// Visits (DSR)
// ---------------------------------------------------------------------------

/** What the sheet sync came to, said in one clause. */
function sheetClause(sync: Awaited<ReturnType<typeof syncVisitsToSheet>>): string {
  if (sync.problem) {
    return ` Saved in Aivy; ${sync.problem}`;
  }
  const made = sync.created ? " (new DSR sheet created in your Drive)" : "";
  return ` Added to the DSR sheet${made}.${sync.url ? `\n${sync.url}` : ""}`;
}

/**
 * The visit goes to Firestore first — that is the record — and then the sheet
 * is brought up to date, which also copies any visit that was saved earlier
 * without a Google token. The closing question is the user's flow: after a
 * visit, ask about the follow-up.
 */
async function commitVisit(
  uid: string,
  d: VisitDraftData,
  opts: CommitOptions,
): Promise<CommitResult> {
  const client = await ensureClient(uid, d.client);
  const visit = await saveVisit(uid, {
    visitDateMs: d.visitDateMs,
    dateLabel: d.dateLabel,
    clientId: client.id,
    clientName: client.name,
    contactPerson: d.contactPerson,
    contactPhone: d.contactPhone,
    location: d.location,
    lat: d.lat ?? null,
    lng: d.lng ?? null,
    visitType: d.visitType,
    products: d.products,
    discussion: d.discussion,
    status: d.status,
    nextStep: d.nextStep,
    followUpMs: 0,
    followUpLabel: "",
    followUpReminderId: "",
  });
  // "Yes, I'm at the client" also files the client as a saved place, so
  // "Bajaj ka location" and directions work afterwards.
  if (d.lat != null && d.lng != null) {
    await savePlace(uid, { name: client.name, lat: d.lat, lng: d.lng, address: d.location }).catch((e) =>
      logger.warn("visit pin not saved as a place", { err: e instanceof Error ? e.message : String(e) }),
    );
  }
  const sync = await syncVisitsToSheet(uid, opts.googleToken, d.timezone);
  const expense = await askForExpense(uid, d.visitDateMs, d.timezone).catch((e) => {
    logger.warn("expense prompt failed", { err: e instanceof Error ? e.message : String(e) });
    return "none" as const;
  });
  const later =
    expense === "ask_now"
      ? " Today's travel expense is not recorded yet and it is past 8 PM: once the follow-up question is settled, ask where they started today."
      : "";
  return {
    ok: true,
    message: `Visit saved — ${client.name}, ${d.dateLabel}.${sheetClause(sync)}\n\nShould I set a follow-up for ${client.name}? (yes / no)`,
    createdIds: [visit.id],
    summary: `visit ${visit.id} ${client.name} ${d.dateLabel} — waiting to hear whether to set a follow-up.${later}`,
  };
}

async function commitVisitFollowup(
  uid: string,
  d: VisitFollowupDraftData,
  opts: CommitOptions,
): Promise<CommitResult> {
  const reminderId = await writeReminder(uid, {
    title: `Follow-up: ${d.clientName}`,
    scheduledMs: d.whenMs,
    type: "followup",
    subType: "visit_followup",
    note: d.note || null,
    clientName: d.clientName,
    extra: { visitId: d.visitId },
  });
  await setVisitFollowUp(uid, d.visitId, {
    followUpMs: d.whenMs,
    followUpLabel: d.whenLabel,
    reminderId,
  });
  const sync = await syncVisitsToSheet(uid, opts.googleToken, d.timezone);
  const sheet = sync.problem ? ` The DSR sheet will show it once Google is connected.` : " DSR sheet updated.";
  return {
    ok: true,
    message: `Follow-up set — ${d.clientName}, ${d.whenLabel}. I'll remind you.${sheet}`,
    createdIds: [reminderId],
    summary: `follow-up ${d.clientName} ${d.whenLabel} (visit ${d.visitId})`,
  };
}

// ---------------------------------------------------------------------------
// Travel expense
// ---------------------------------------------------------------------------

const EXPENSE_PROMPT_HOUR = 20;

/**
 * On a day with visits, the user wants Aivy to ask for the expense at 8 PM.
 * The first visit of the day sets that one reminder (fixed id, so a second
 * visit does not add another); a visit saved after 8 PM asks in the chat
 * instead. Nothing happens when the day's travel is already in.
 */
async function askForExpense(
  uid: string,
  visitMs: number,
  timezone: string,
): Promise<"scheduled" | "ask_now" | "none"> {
  const now = DateTime.now().setZone(timezone);
  const today = dayKey(now.toMillis(), timezone);
  if (dayKey(visitMs, timezone) !== today) return "none";
  if (await getExpense(uid, today)) return "none";
  const at = now.startOf("day").set({ hour: EXPENSE_PROMPT_HOUR });
  if (now >= at) return "ask_now";
  const id = expensePromptId(today);
  const existing = await userRef(uid).collection("reminders").doc(id).get();
  if (existing.exists) return "scheduled";
  await writeReminder(uid, {
    id,
    title: "Travel expense — tell Aivy where you started today",
    scheduledMs: at.toMillis(),
    type: "reminder",
    subType: "expense_prompt",
    note: "Aivy will measure the km from today's visits and add them to the expense sheet.",
  });
  return "scheduled";
}

async function commitTravelExpense(
  uid: string,
  d: TravelExpenseDraftData,
  opts: CommitOptions,
): Promise<CommitResult> {
  if (await getExpense(uid, d.day)) {
    return { ok: false, message: `Travel for ${d.dateLabel} is already recorded.`, createdIds: [], summary: "" };
  }
  await saveExpense(uid, {
    id: d.day,
    dateMs: d.dateMs,
    dateLabel: d.dateLabel,
    startPoint: d.startPoint,
    endPoint: d.endPoint,
    vehicle: d.vehicle,
    ratePerKm: d.ratePerKm,
    legs: d.legs,
    totalKm: d.totalKm,
    totalAmount: d.totalAmount,
  });
  // The 8 PM ask is answered, whenever it was.
  await cancelReminders(uid, [expensePromptId(d.day)]);
  const sync = await syncExpensesToSheet(uid, opts.googleToken, d.timezone);
  const sheet = sync.problem
    ? ` Saved in Aivy; ${sync.problem}`
    : ` Added to the expense sheet${sync.created ? " (new sheet created in your Drive)" : ""}.${sync.url ? `\n${sync.url}` : ""}`;
  return {
    ok: true,
    message: `Travel saved — ${d.dateLabel}: ${d.totalKm} km × ₹${d.ratePerKm} = ₹${d.totalAmount}.${sheet}`,
    createdIds: [d.day],
    summary: `travel expense ${d.dateLabel} ${d.totalKm} km ₹${d.totalAmount}`,
  };
}

async function commitSavedContact(
  uid: string,
  d: SavedContactDraftData,
): Promise<CommitResult> {
  const contact = await saveContact(uid, {
    name: d.name,
    phone: d.phone || null,
    company: d.company || null,
    email: d.email || null,
    notes: d.notes || null,
    source: "visiting_card",
    cardImages: d.cardImages ?? [],
    existingId: d.existingId,
  });
  const who = [contact.name, contact.company].filter(Boolean).join(" · ");
  const sides = contact.cardImages?.length ?? 0;
  return {
    ok: true,
    message: d.replacing ? `Updated ${who}.` : `Saved ${who}.`,
    createdIds: [contact.id],
    summary:
      `saved contact ${contact.name} (contact_id ${contact.id}, ${sides} card photo${sides === 1 ? "" : "s"})` +
      (sides === 1 ? " — if they now send the back of this card, pass this contact_id" : ""),
  };
}

async function commitLibraryItem(
  uid: string,
  d: LibraryItemDraftData,
): Promise<CommitResult> {
  const item = await saveLibraryItem(uid, {
    title: d.title,
    kind: d.libraryKind,
    sourceName: d.sourceName || null,
    mimeType: d.mimeType || null,
    storagePath: d.storagePath || null,
    excerpt: d.excerpt || null,
    facts: d.facts,
    existingId: d.existingId,
  });
  const n = item.facts.length;
  const factsNote = n === 0 ? "" : n === 1 ? ", 1 fact" : `, ${n} facts`;
  return {
    ok: true,
    message: d.replacing
      ? `Updated "${item.title}" in the library${factsNote}.`
      : `Filed "${item.title}" in the library${factsNote}.`,
    createdIds: [item.id],
    summary: `library ${item.kind} ${item.title}`,
  };
}

/** Replays one confirmed draft. Idempotent: a committed draft is not redone. */
export async function commitDraft(
  uid: string,
  draftId: string,
  opts: CommitOptions = {},
): Promise<CommitResult> {
  const draft: AgentDraft | null = await getDraft(uid, draftId);
  if (!draft) {
    return { ok: false, message: "Draft not found.", createdIds: [], summary: "" };
  }
  if (draft.status === "committed") {
    return {
      ok: true,
      message: "This was already saved.",
      createdIds: draft.resultIds ?? [],
      summary: "",
    };
  }
  if (draft.status === "cancelled") {
    return { ok: false, message: "This draft was cancelled.", createdIds: [], summary: "" };
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
    case "saved_place":
      result = await commitSavedPlace(uid, draft.data);
      break;
    case "saved_contact":
      result = await commitSavedContact(uid, draft.data);
      break;
    case "library_item":
      result = await commitLibraryItem(uid, draft.data);
      break;
    case "project_items":
      result = await commitProjectItems(uid, draft.data);
      break;
    case "task":
      result = await commitTask(uid, draft.data);
      break;
    case "visit":
      result = await commitVisit(uid, draft.data, opts);
      break;
    case "visit_followup":
      result = await commitVisitFollowup(uid, draft.data, opts);
      break;
    case "travel_expense":
      result = await commitTravelExpense(uid, draft.data, opts);
      break;
    default:
      return { ok: false, message: "Unknown draft type.", createdIds: [], summary: "" };
  }

  if (result.ok) {
    await markDraftStatus(uid, draftId, "committed", result.createdIds);
  }
  return result;
}

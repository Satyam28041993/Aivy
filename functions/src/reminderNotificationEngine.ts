import { randomUUID } from "node:crypto";
import {
  getFirestore,
  FieldValue,
  Timestamp,
  type DocumentData,
  type DocumentReference,
} from "firebase-admin/firestore";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { logger } from "firebase-functions";
import { DateTime } from "luxon";
import { getDashboardEngineStats } from "./clientStats";
import { pushToUser } from "./push";

const REGION = "us-central1";
const NOTIFICATIONS = "notifications";
const USERS = "users";

export type InAppNotificationType = "payment_due" | "overdue" | "followup";

type CreateInAppParams = {
  userId: string;
  title: string;
  message: string;
  type: InAppNotificationType;
  read?: boolean;
  reminderId?: string;
  paymentId?: string;
  clientName?: string;
  groupKey?: string;
  amount?: number;
  dedupeKey?: string;
};

/**
 * Reusable: persist one row in `users/{userId}/notifications/{id}`.
 * Uses optional [dedupeKey] to avoid duplicate in-app lines for the same event.
 */
export async function createNotification(
  p: CreateInAppParams,
): Promise<string> {
  const db = getFirestore();
  if (p.dedupeKey && p.dedupeKey.length > 0) {
    const q = await db
      .collection(USERS)
      .doc(p.userId)
      .collection(NOTIFICATIONS)
      .where("dedupeKey", "==", p.dedupeKey)
      .limit(1)
      .get();
    if (!q.empty) {
      return q.docs[0]!.id;
    }
  }
  const id = randomUUID();
  const ref = db
    .collection(USERS)
    .doc(p.userId)
    .collection(NOTIFICATIONS)
    .doc(id);
  await ref.set({
    id,
    title: p.title,
    message: p.message,
    type: p.type,
    read: p.read === true,
    createdAt: FieldValue.serverTimestamp(),
    createdAtMs: Date.now(),
    reminderId: p.reminderId ?? null,
    paymentId: p.paymentId ?? null,
    clientName: p.clientName ?? null,
    groupKey: p.groupKey ?? null,
    amount: p.amount != null && Number.isFinite(p.amount) ? p.amount : null,
    dedupeKey: p.dedupeKey ?? null,
  });
  // eslint-disable-next-line no-console
  console.log("Notification created", { id, userId: p.userId, type: p.type });
  logger.info("Notification created", { id, userId: p.userId, type: p.type });

  // The row above is only visible with the app open. This is what reaches the
  // phone. It is awaited but never allowed to throw: delivery failing must not
  // undo the notification.
  await pushToUser(p.userId, {
    title: p.title,
    body: p.message,
    data: {
      type: p.type,
      notificationId: id,
      ...(p.reminderId ? { reminderId: p.reminderId } : {}),
    },
  });
  return id;
}

function formatRupees(n: number): string {
  return new Intl.NumberFormat("en-IN", {
    maximumFractionDigits: 0,
  }).format(Math.round(n));
}

function readScheduledMs(d: DocumentData): number {
  const m = (d as { scheduledTimeMs?: unknown }).scheduledTimeMs;
  if (typeof m === "number" && Number.isFinite(m) && m > 0) {
    return m;
  }
  const r = (d as { remindAt?: unknown }).remindAt;
  if (r && typeof (r as { toMillis?: () => number }).toMillis === "function") {
    return (r as { toMillis: () => number }).toMillis();
  }
  const st = (d as { scheduledTime?: unknown }).scheduledTime;
  if (st && typeof (st as { toMillis?: () => number }).toMillis === "function") {
    return (st as { toMillis: () => number }).toMillis();
  }
  return 0;
}

function readPaymentDueMs(pay: DocumentData): number {
  const n = (pay as { dueDateMs?: unknown }).dueDateMs;
  if (typeof n === "number" && Number.isFinite(n) && n > 0) {
    return n;
  }
  const pdm = (pay as { paymentDueDateMs?: unknown }).paymentDueDateMs;
  if (typeof pdm === "number" && Number.isFinite(pdm) && pdm > 0) {
    return pdm;
  }
  const pd = (pay as { dueDate?: unknown }).dueDate;
  if (pd && typeof (pd as { toMillis?: () => number }).toMillis === "function") {
    return (pd as { toMillis: () => number }).toMillis();
  }
  return 0;
}

function isPaymentPaid(pay: DocumentData): boolean {
  const s = String((pay as { status?: string }).status ?? "")
    .trim()
    .toLowerCase();
  return s === "paid" || s === "completed" || s === "cancelled";
}

function dueDateLineFromMs(ms: number, timeZone: string): string {
  const z = (timeZone && timeZone.trim()) || "Asia/Kolkata";
  const d = DateTime.fromMillis(ms, { zone: "UTC" }).setZone(z);
  if (!d.isValid) {
    return new Date(ms).toDateString();
  }
  return d.toFormat("d MMM yyyy");
}

function userIdFromReminderPath(
  p: string | undefined,
  collectionId: string,
): string | null {
  if (!p || !collectionId) {
    return null;
  }
  const parts = p.split("/");
  const i = parts.indexOf("users");
  if (i < 0 || i + 1 >= parts.length) {
    return null;
  }
  return parts[i + 1] ?? null;
}

/**
 * Every 5 minutes: pending reminders whose scheduled time has passed → in-app
 * notification, reminder = sent, payment touch fields.
 */
export const checkReminders = onSchedule(
  {
    schedule: "every 5 minutes",
    region: REGION,
    memory: "512MiB",
  },
  async () => {
    const db = getFirestore();
    const now = Timestamp.now();
    const nowMs = now.toMillis();
    const col = db.collectionGroup("reminders");
    let snap;
    try {
      snap = await col
        .where("status", "==", "pending")
        .where("scheduledTimeMs", "<=", nowMs)
        .orderBy("scheduledTimeMs", "asc")
        .limit(200)
        .get();
    } catch (e) {
      logger.error("checkReminders query failed, retrying without orderBy", {
        err: e instanceof Error ? e.message : String(e),
      });
      snap = await col
        .where("status", "==", "pending")
        .where("scheduledTimeMs", "<=", nowMs)
        .limit(200)
        .get();
    }

    for (const doc of snap.docs) {
      const reminderId = doc.id;
      const r = doc.data() as DocumentData;
      const userId = userIdFromReminderPath(doc.ref.path, doc.ref.id);
      if (!userId) {
        // eslint-disable-next-line no-console
        console.log("checkReminders: skip, no user in path", doc.ref.path);
        continue;
      }
      // eslint-disable-next-line no-console
      console.log("Reminder triggered:", reminderId);

      try {
        await db.runTransaction(async (t) => {
          const rSnap = await t.get(doc.ref);
          if (!rSnap.exists) {
            return;
          }
          const r2 = rSnap.data() as DocumentData;
          if (String(r2.status ?? "").toLowerCase() !== "pending") {
            return;
          }
          const stMs = readScheduledMs(r2);
          if (stMs <= 0 || stMs > nowMs) {
            return;
          }

          const payId = String(
            (r2 as { paymentId?: string }).paymentId ?? "",
          ).trim();
          let payRef: DocumentReference | null = null;
          let pData0: DocumentData | null = null;
          if (payId.length > 0) {
            const pref = db
              .collection(USERS)
              .doc(userId)
              .collection("payments")
              .doc(payId);
            const pSnap = await t.get(pref);
            if (pSnap.exists) {
              const pD = pSnap.data() as DocumentData;
              if (isPaymentPaid(pD)) {
                t.update(doc.ref, {
                  status: "completed",
                  cancelReason: "payment_paid",
                  updatedAtMs: nowMs,
                });
                return;
              }
              payRef = pref;
              pData0 = pD;
            }
          }

          const clientName = String(
            (pData0 as { clientName?: string } | null)?.clientName ??
              (r2 as { clientName?: string }).clientName ??
              (r2 as { clientLabel?: string }).clientLabel ??
              (r2 as { displayClientName?: string }).displayClientName ??
              "Client",
          ).trim();
          const amt0 = Number(
            (pData0 as { amount?: number } | null)?.amount ?? NaN,
          );
          const amount = Number.isFinite(amt0) && amt0 > 0
            ? amt0
            : Number(
                (r2 as { amount?: number }).amount ??
                  (r2 as { orderAmountInr?: number }).orderAmountInr ??
                  0,
              );
          const isFollow = Boolean(
            (r2 as { isFollowUp?: boolean }).isFollowUp,
          );
          const timeZone = String(
            (r2 as { userTimeZone?: string }).userTimeZone ?? "Asia/Kolkata",
          );
          const dueMs = (pData0 && readPaymentDueMs(pData0) > 0
            ? readPaymentDueMs(pData0)
            : readPaymentDueMs(r2)) || stMs;
          const dateLine = dueDateLineFromMs(dueMs, timeZone);
          const ru = formatRupees(Number.isFinite(amount) ? amount : 0);
          let nType: InAppNotificationType = "payment_due";
          if (isFollow) {
            nType = "followup";
          } else if (pData0) {
            const due = readPaymentDueMs(pData0);
            const st0 = String((pData0 as { status?: string }).status ?? "")
              .trim()
              .toLowerCase();
            if (st0 === "overdue" || (due > 0 && due < nowMs)) {
              nType = "overdue";
            }
          } else if (Number.isFinite(dueMs) && dueMs < nowMs) {
            nType = "overdue";
          }

          const payIdLen = payId.length > 0;
          const docTitle = String((r2 as { title?: string }).title ?? "").trim();
          const docDesc = String((r2 as { description?: string }).description ?? "").trim();
          let title: string;
          let message: string;
          if (isFollow) {
            title = "Follow-up";
            message = `Follow up with ${clientName}${dateLine ? " · " + dateLine : ""}.`;
          } else if (payIdLen && pData0) {
            title = "Payment Reminder";
            message = `₹${ru} from ${clientName} due on ${dateLine}`;
          } else if (!payIdLen) {
            const t0 = docTitle || String((r2 as { message?: string }).message ?? "").trim() || "Reminder";
            title = t0;
            message = docDesc.length > 0 ? `${t0} — ${docDesc}` : t0;
            if (dateLine.length > 0) {
              message = `${message} · ${dateLine}`;
            }
          } else {
            title = docTitle || "Payment Reminder";
            message = `₹${ru} from ${clientName} due on ${dateLine}`;
          }

          if (!isFollow && !payIdLen && nType === "payment_due") {
            nType = "followup";
          }

          const nDedupe = `reminder_fired:${reminderId}`;

          const nid = randomUUID();
          const nRef = db
            .collection(USERS)
            .doc(userId)
            .collection(NOTIFICATIONS)
            .doc(nid);
          t.set(nRef, {
            id: nid,
            title,
            message,
            type: nType,
            read: false,
            createdAt: FieldValue.serverTimestamp(),
            createdAtMs: nowMs,
            reminderId,
            paymentId: payId || null,
            clientName: clientName || null,
            groupKey: String(
              (r2 as { clientKey?: string }).clientKey ?? "",
            ).trim() || null,
            amount: Number.isFinite(amount) ? amount : null,
            dedupeKey: nDedupe,
          });

          t.update(doc.ref, {
            status: "sent",
            sentAt: FieldValue.serverTimestamp(),
            sentAtMs: nowMs,
            channel:
              String((r2 as { channel?: string }).channel ?? "in_app") || "in_app",
          });

          if (payId && payRef) {
            t.update(payRef, {
              lastReminderSentAt: FieldValue.serverTimestamp(),
              lastReminderSentAtMs: nowMs,
              reminderDates: FieldValue.arrayUnion(
                Timestamp.fromMillis(stMs),
              ),
            });
          }
        });
        // eslint-disable-next-line no-console
        console.log("Notification created");

        // Written inside the transaction above, so it does not go through
        // createNotification and needs sending on its own. Read back rather
        // than recomputed, so the phone shows exactly the stored line.
        const fired = await db
          .collection(USERS)
          .doc(userId)
          .collection(NOTIFICATIONS)
          .where("dedupeKey", "==", `reminder_fired:${reminderId}`)
          .limit(1)
          .get();
        const row = fired.docs[0]?.data();
        if (row) {
          await pushToUser(userId, {
            title: String(row.title ?? "Reminder"),
            body: String(row.message ?? ""),
            data: { type: String(row.type ?? "followup"), reminderId },
          });
        }
      } catch (err) {
        logger.error("checkReminders: transaction failed", {
          reminderId,
          err: err instanceof Error ? err.message : String(err),
        });
      }

      // Future WhatsApp delivery (separate from in-app write)
      const ch = String(
        (r as { channel?: string }).channel ?? "in_app",
      ).toLowerCase();
      if (ch === "whatsapp_future") {
        // Placeholder: call sendWhatsApp function later
        // eslint-disable-next-line no-console
        console.log("WhatsApp future channel (placeholder)", { reminderId });
        logger.info("WhatsApp future channel (placeholder)", { reminderId });
      }
    }
  },
);

/**
 * Every hour: mark still-open payment rows with due in the past as `overdue`.
 */
export const markOverdue = onSchedule(
  {
    schedule: "every 60 minutes",
    region: REGION,
    memory: "256MiB",
  },
  async () => {
    const db = getFirestore();
    const nowMs = Date.now();
    const snap = await db
      .collectionGroup("payments")
      .where("status", "==", "pending")
      .where("dueDateMs", "<", nowMs)
      .limit(500)
      .get();
    if (snap.empty) {
      return;
    }
    const batch = db.batch();
    let n = 0;
    for (const doc of snap.docs) {
      const d = doc.data() as DocumentData;
      const dm = readPaymentDueMs(d);
      if (dm <= 0) {
        continue;
      }
      if (isPaymentPaid(d)) {
        continue;
      }
      if (String(d.status ?? "").toLowerCase() !== "pending") {
        continue;
      }
      batch.update(doc.ref, {
        status: "overdue",
        updatedAtMs: nowMs,
        updatedAt: FieldValue.serverTimestamp(),
      });
      n += 1;
      if (n >= 400) {
        break;
      }
    }
    if (n > 0) {
      await batch.commit();
      // eslint-disable-next-line no-console
      console.log("markOverdue: updated", n, "rows");
      logger.info("markOverdue: updated", { n });
    }
  },
);

export const getDashboardStats = onCall(
  { region: REGION },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Auth required");
    }
    const raw = (request.data as { timeZone?: string } | undefined)?.timeZone;
    const timeZone =
      typeof raw === "string" && raw.trim().length > 0
        ? raw.trim()
        : "Asia/Kolkata";
    const s = await getDashboardEngineStats(request.auth.uid, timeZone);
    return {
      todayDueCount: s.todayDueCount,
      overdueCount: s.overdueCount,
      followUpsToday: s.followUpsToday,
      totalPendingAmount: s.totalPendingAmount,
    };
  },
);

export const markNotificationRead = onCall(
  { region: REGION },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Auth required");
    }
    const uid = request.auth.uid;
    const data = request.data as
      | { notificationId?: string; read?: boolean; markAllRead?: boolean }
      | undefined;
    const db = getFirestore();
    if (data?.markAllRead === true) {
      const q = await db
        .collection(USERS)
        .doc(uid)
        .collection(NOTIFICATIONS)
        .where("read", "==", false)
        .limit(500)
        .get();
      if (q.empty) {
        return { ok: true, count: 0 };
      }
      const b = db.batch();
      for (const d of q.docs) {
        b.update(d.ref, { read: true, readAt: FieldValue.serverTimestamp() });
      }
      await b.commit();
      return { ok: true, count: q.size };
    }
    const id = (data?.notificationId ?? "").trim();
    if (!id) {
      throw new HttpsError("invalid-argument", "notificationId required");
    }
    await db
      .collection(USERS)
      .doc(uid)
      .collection(NOTIFICATIONS)
      .doc(id)
      .set(
        { read: data?.read !== false, readAt: FieldValue.serverTimestamp() },
        { merge: true },
      );
    return { ok: true };
  },
);

/**
 * When a payment becomes paid, cancel any still-pending engine reminders.
 */
export const onPaymentWriteCancelReminders = onDocumentWritten(
  { region: REGION, document: "users/{userId}/payments/{paymentId}" },
  async (event) => {
    const after = event.data?.after.data() as DocumentData | undefined;
    if (!after) {
      return;
    }
    const s = String(after.status ?? "").trim().toLowerCase();
    if (s !== "paid" && s !== "completed" && s !== "received" && s !== "cancelled") {
      return;
    }
    const before = event.data?.before.data() as DocumentData | undefined;
    const beforeS = String(before?.status ?? "")
      .trim()
      .toLowerCase();
    if (
      beforeS === "paid" ||
      beforeS === "completed" ||
      beforeS === "received" ||
      beforeS === "cancelled"
    ) {
      return;
    }
    const uid = event.params["userId"] as string;
    const payId = event.params["paymentId"] as string;
    const db = getFirestore();
    const rs = await db
      .collection(USERS)
      .doc(uid)
      .collection("reminders")
      .where("paymentId", "==", payId)
      .get();
    if (rs.empty) {
      return;
    }
    const b = db.batch();
    const nowMs = Date.now();
    for (const d of rs.docs) {
      const st = String(d.data().status ?? "")
        .trim()
        .toLowerCase();
      if (st === "pending") {
        b.update(d.ref, {
          status: "completed",
          cancelReason: "payment_paid",
          updatedAtMs: nowMs,
        });
      }
    }
    await b.commit();
  },
);

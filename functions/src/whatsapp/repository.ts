import {
  FieldValue,
  Timestamp,
  getFirestore,
  type DocumentReference,
} from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import type { ParsedInboundMessage, ParsedStatusEvent } from "./types";
import { withRetry } from "./retry";
import { ensureContactFromWhatsAppInbound } from "../contacts/ensureFromWhatsApp";

type MessageDoc = {
  id: string;
  conversationId: string;
  from: string;
  profileName: string | null;
  direction: "inbound";
  type: string;
  textBody: string | null;
  media: ParsedInboundMessage["media"];
  status: {
    sentAtSec: number | null;
    deliveredAtSec: number | null;
    readAtSec: number | null;
    failedAtSec: number | null;
    lastStatus: string;
    lastStatusAtSec: number | null;
  };
  messageTimestampSec: number | null;
  messageTimestamp: Timestamp | null;
  ai: {
    queued: boolean;
    queuedAt: FirebaseFirestore.FieldValue;
    processed: boolean;
    autoReplyEligible: boolean;
  };
  rawPayload: Record<string, unknown>;
  createdAt: FirebaseFirestore.FieldValue;
  createdAtMs: number;
  updatedAt: FirebaseFirestore.FieldValue;
  updatedAtMs: number;
};

function toTimestampOrNull(timestampSec: number | null): Timestamp | null {
  if (!timestampSec || !Number.isFinite(timestampSec) || timestampSec <= 0) {
    return null;
  }
  return Timestamp.fromMillis(timestampSec * 1000);
}

function messageRef(conversationId: string, messageId: string): DocumentReference {
  return getFirestore()
    .collection("whatsapp_conversations")
    .doc(conversationId)
    .collection("whatsapp_messages")
    .doc(messageId);
}

function messageIndexRef(messageId: string): DocumentReference {
  return getFirestore().collection("whatsapp_message_index").doc(messageId);
}

async function writeAdminActivityLog(event: {
  eventType: string;
  severity?: "info" | "warn" | "error";
  conversationId?: string | null;
  messageId?: string | null;
  phone?: string | null;
  status?: string | null;
  details?: Record<string, unknown>;
}): Promise<void> {
  const nowMs = Date.now();
  await withRetry("writeAdminActivityLog", async () => {
    await getFirestore()
      .collection("admin_activity_logs")
      .add({
        source: "whatsapp_webhook",
        eventType: event.eventType,
        severity: event.severity ?? "info",
        conversationId: event.conversationId ?? null,
        messageId: event.messageId ?? null,
        phone: event.phone ?? null,
        status: event.status ?? null,
        details: event.details ?? null,
        createdAt: FieldValue.serverTimestamp(),
        createdAtMs: nowMs,
      });
  });
}

async function writePendingStatus(statusEvent: ParsedStatusEvent): Promise<void> {
  await withRetry("writePendingStatus", async () => {
    await getFirestore()
      .collection("whatsapp_pending_status")
      .doc(statusEvent.messageId)
      .set(
        {
          messageId: statusEvent.messageId,
          recipient: statusEvent.recipient,
          status: statusEvent.status,
          timestampSec: statusEvent.timestampSec,
          conversationId: statusEvent.conversationId,
          pricingCategory: statusEvent.pricingCategory,
          raw: statusEvent.raw,
          updatedAt: FieldValue.serverTimestamp(),
          updatedAtMs: Date.now(),
        },
        { merge: true },
      );
  });
}

// Keys with dots are resolved as nested field paths only by update(), NOT by
// set()+merge.  Keep plain dotted strings here and call tx.update() (not set).
function buildStatusPatch(
  statusEvent: ParsedStatusEvent,
  nowMs: number,
): Record<string, unknown> {
  const patch: Record<string, unknown> = {
    "status.lastStatus": statusEvent.status,
    "status.lastStatusAtSec": statusEvent.timestampSec,
    updatedAt: FieldValue.serverTimestamp(),
    updatedAtMs: nowMs,
  };
  if (statusEvent.status === "sent") {
    patch["status.sentAtSec"] = statusEvent.timestampSec;
  } else if (statusEvent.status === "delivered") {
    patch["status.deliveredAtSec"] = statusEvent.timestampSec;
  } else if (statusEvent.status === "read") {
    patch["status.readAtSec"] = statusEvent.timestampSec;
  } else if (statusEvent.status === "failed") {
    patch["status.failedAtSec"] = statusEvent.timestampSec;
  }
  return patch;
}

export async function upsertInboundMessage(msg: ParsedInboundMessage): Promise<void> {
  const nowMs = Date.now();
  const conversationRef = getFirestore()
    .collection("whatsapp_conversations")
    .doc(msg.conversationId);
  const msgRef = messageRef(msg.conversationId, msg.messageId);
  const idxRef = messageIndexRef(msg.messageId);
  const messageDoc: MessageDoc = {
    id: msg.messageId,
    conversationId: msg.conversationId,
    from: msg.from,
    profileName: msg.profileName,
    direction: "inbound",
    type: msg.type,
    textBody: msg.textBody,
    media: msg.media,
    status: {
      sentAtSec: null,
      deliveredAtSec: null,
      readAtSec: null,
      failedAtSec: null,
      lastStatus: "received",
      lastStatusAtSec: msg.timestampSec,
    },
    messageTimestampSec: msg.timestampSec,
    messageTimestamp: toTimestampOrNull(msg.timestampSec),
    ai: {
      queued: true,
      queuedAt: FieldValue.serverTimestamp(),
      processed: false,
      autoReplyEligible: true,
    },
    rawPayload: msg.raw,
    createdAt: FieldValue.serverTimestamp(),
    createdAtMs: nowMs,
    updatedAt: FieldValue.serverTimestamp(),
    updatedAtMs: nowMs,
  };

  await withRetry("upsertInboundMessage", async () => {
    await getFirestore().runTransaction(async (tx) => {
      const existing = await tx.get(msgRef);
      if (!existing.exists) {
        tx.set(msgRef, messageDoc, { merge: true });
      } else {
        tx.set(
          msgRef,
          {
            rawPayload: msg.raw,
            updatedAt: FieldValue.serverTimestamp(),
            updatedAtMs: nowMs,
          },
          { merge: true },
        );
      }

      tx.set(
        conversationRef,
        {
          id: msg.conversationId,
          from: msg.from,
          profileName: msg.profileName,
          lastMessageAt: FieldValue.serverTimestamp(),
          lastMessageAtMs: nowMs,
          lastMessageType: msg.type,
          lastMessageTextPreview: msg.textBody ?? null,
          lastDirection: "inbound",
          updatedAt: FieldValue.serverTimestamp(),
          updatedAtMs: nowMs,
          incomingCount: FieldValue.increment(1),
          unreadCountAdmin: FieldValue.increment(1),
        },
        { merge: true },
      );

      tx.set(
        idxRef,
        {
          messageId: msg.messageId,
          conversationId: msg.conversationId,
          from: msg.from,
          profileName: msg.profileName,
          lastStatus: "received",
          lastStatusAtSec: msg.timestampSec,
          updatedAt: FieldValue.serverTimestamp(),
          updatedAtMs: nowMs,
        },
        { merge: true },
      );
    });
  });

  await writeAdminActivityLog({
    eventType: "inbound_message_saved",
    messageId: msg.messageId,
    conversationId: msg.conversationId,
    phone: msg.from,
    details: { type: msg.type },
  });

  try {
    await ensureContactFromWhatsAppInbound({
      from: msg.from,
      profileName: msg.profileName,
    });
  } catch (e) {
    logger.warn("[contacts] auto-save from inbound failed", {
      message: e instanceof Error ? e.message : String(e),
    });
  }
}

export async function applyStatusEvent(statusEvent: ParsedStatusEvent): Promise<void> {
  const nowMs = Date.now();
  const idxRef = messageIndexRef(statusEvent.messageId);
  const idxSnap = await withRetry("readMessageIndex", () => idxRef.get());
  if (!idxSnap.exists) {
    logger.warn("[whatsapp] status event without index", {
      messageId: statusEvent.messageId,
      status: statusEvent.status,
    });
    await writePendingStatus(statusEvent);
    await writeAdminActivityLog({
      eventType: "status_orphaned",
      severity: "warn",
      messageId: statusEvent.messageId,
      phone: statusEvent.recipient,
      status: statusEvent.status,
    });
    return;
  }

  const idx = idxSnap.data() ?? {};
  const conversationId = String(idx.conversationId ?? "").trim();
  if (!conversationId) {
    return;
  }
  const msgRef = messageRef(conversationId, statusEvent.messageId);
  const statusPatch = buildStatusPatch(statusEvent, nowMs);

  await withRetry("applyStatusEvent", async () => {
    await getFirestore().runTransaction(async (tx) => {
      // update() resolves dotted keys as nested field paths; set+merge does not.
      tx.update(msgRef, statusPatch);
      tx.update(idxRef, {
        lastStatus: statusEvent.status,
        lastStatusAtSec: statusEvent.timestampSec,
        updatedAt: FieldValue.serverTimestamp(),
        updatedAtMs: nowMs,
      });
      tx.set(
        getFirestore().collection("whatsapp_conversations").doc(conversationId),
        {
          lastDeliveryStatus: statusEvent.status,
          lastDeliveryStatusAtSec: statusEvent.timestampSec,
          updatedAt: FieldValue.serverTimestamp(),
          updatedAtMs: nowMs,
        },
        { merge: true },
      );
      tx.delete(getFirestore().collection("whatsapp_pending_status").doc(statusEvent.messageId));
    });
  });

  await writeAdminActivityLog({
    eventType: "delivery_status_updated",
    messageId: statusEvent.messageId,
    conversationId,
    phone: statusEvent.recipient,
    status: statusEvent.status,
  });
}

export async function applyPendingStatusForMessageIndex(messageId: string): Promise<void> {
  const pendingRef = getFirestore().collection("whatsapp_pending_status").doc(messageId);
  const pendingSnap = await withRetry("readPendingStatus", () => pendingRef.get());
  if (!pendingSnap.exists) {
    return;
  }
  const p = pendingSnap.data() ?? {};
  const statusEvent: ParsedStatusEvent = {
    messageId,
    recipient: (p.recipient as string | undefined) ?? null,
    status: ((p.status as string | undefined) ?? "unknown") as ParsedStatusEvent["status"],
    timestampSec: (p.timestampSec as number | undefined) ?? null,
    conversationId: (p.conversationId as string | undefined) ?? null,
    pricingCategory: (p.pricingCategory as string | undefined) ?? null,
    raw: (p.raw as Record<string, unknown> | undefined) ?? {},
  };
  await applyStatusEvent(statusEvent);
}

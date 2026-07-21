import { logger } from "firebase-functions";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

// eslint-disable-next-line @typescript-eslint/no-require-imports
const { sendWhatsAppMessageOrTemplate } = require("../services/whatsappService.js") as {
  sendWhatsAppMessageOrTemplate: (
    to: string,
    message: string,
    opts?: { contactName?: string },
  ) => Promise<{ messageId: string; raw: unknown; usedTemplate?: boolean }>;
};

function normalizeIndiaPhone(raw: unknown): string | null {
  if (typeof raw !== "string") {
    return null;
  }
  const d = raw.replace(/\D/g, "");
  if (d.length === 12 && d.startsWith("91")) {
    return d;
  }
  if (d.length === 10) {
    return `91${d}`;
  }
  if (d.length >= 10 && d.length <= 15) {
    return d;
  }
  return null;
}

function validateMessageText(message: unknown): string {
  if (typeof message !== "string") {
    throw new HttpsError("invalid-argument", "message string required");
  }
  const text = message.trim();
  if (!text) {
    throw new HttpsError("invalid-argument", "Message khali hai");
  }
  if (text.length > 4000) {
    throw new HttpsError("invalid-argument", "Message bahut lamba hai");
  }
  return text;
}

async function assertCanSendToPhone(uid: string, phone: string): Promise<void> {
  const db = getFirestore();
  const snap = await db
    .collection("contacts")
    .where("ownerUid", "==", uid)
    .where("phone", "==", phone)
    .limit(1)
    .get();
  if (!snap.empty) {
    return;
  }
  throw new HttpsError(
    "permission-denied",
    "Yeh number aapke Contacts me nahi mila. Pehle Contacts me save karein, phir bhejein.",
  );
}

/** Display name for inbox / conversation header (matches inbound `profileName`). */
async function resolveContactProfileName(
  uid: string,
  phone: string,
): Promise<string | null> {
  const db = getFirestore();
  const snap = await db
    .collection("contacts")
    .where("ownerUid", "==", uid)
    .where("phone", "==", phone)
    .limit(1)
    .get();
  if (snap.empty) {
    return null;
  }
  const raw = snap.docs[0].data()?.name;
  const n = typeof raw === "string" ? raw.trim() : "";
  return n.length > 0 ? n : null;
}

async function persistOutboundCopy(args: {
  conversationId: string;
  phone: string;
  text: string;
  messageId: string;
  profileName: string | null;
}): Promise<void> {
  const db = getFirestore();
  const { conversationId, phone, text, messageId, profileName } = args;
  const nowMs = Date.now();
  const id =
    messageId.trim().length > 0
      ? messageId
      : db.collection("whatsapp_conversations").doc().id;

  await db
    .collection("whatsapp_conversations")
    .doc(conversationId)
    .collection("whatsapp_messages")
    .doc(id)
    .set(
      {
        id,
        conversationId,
        from: "admin",
        direction: "outbound",
        type: "text",
        textBody: text,
        uiReadByAdmin: true,
        status: {
          lastStatus: "sent",
          sentAtSec: Math.floor(nowMs / 1000),
          lastStatusAtSec: Math.floor(nowMs / 1000),
        },
        createdAt: FieldValue.serverTimestamp(),
        createdAtMs: nowMs,
        updatedAt: FieldValue.serverTimestamp(),
        updatedAtMs: nowMs,
      },
      { merge: true },
    );

  await db.collection("whatsapp_message_index").doc(id).set(
    {
      messageId: id,
      conversationId,
      from: phone.trim(),
      profileName: "Admin",
      lastStatus: "sent",
      lastStatusAtSec: Math.floor(nowMs / 1000),
      updatedAt: FieldValue.serverTimestamp(),
      updatedAtMs: nowMs,
    },
    { merge: true },
  );

  const convoPatch: Record<string, unknown> = {
    from: phone.trim(),
    lastMessageTextPreview: text,
    lastMessageType: "text",
    lastDirection: "outbound",
    lastDeliveryStatus: "sent",
    lastDeliveryStatusAtSec: Math.floor(nowMs / 1000),
    lastMessageAt: FieldValue.serverTimestamp(),
    lastMessageAtMs: nowMs,
    updatedAt: FieldValue.serverTimestamp(),
    updatedAtMs: nowMs,
  };
  if (profileName != null && profileName.trim().length > 0) {
    convoPatch.profileName = profileName.trim();
  }

  await db.collection("whatsapp_conversations").doc(conversationId).set(convoPatch, {
    merge: true,
  });
}

/**
 * Authenticated outbound WhatsApp for CRM contacts (non-admin users).
 * Verifies [phone] exists in `contacts` for the caller unless caller has admin claim.
 */
export const userSendWhatsapp = onCall(
  {
    region: "us-central1",
  },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Authentication required");
    }
    const uid = request.auth.uid;
    const isAdmin = request.auth.token?.admin === true;

    const body =
      typeof request.data === "object" && request.data !== null
        ? (request.data as { phone?: unknown; message?: unknown; contactName?: unknown })
        : {};

    const phoneRaw = body.phone;
    const messageRaw = body.message;
    const contactNameRaw = body.contactName;
    const contactNameFromClient =
      typeof contactNameRaw === "string" ? contactNameRaw.trim() : "";

    const phone = normalizeIndiaPhone(phoneRaw);
    if (phone == null) {
      throw new HttpsError(
        "invalid-argument",
        "Phone 91XXXXXXXXXX ya 10 digit Indian mobile hona chahiye",
      );
    }
    const text = validateMessageText(messageRaw);

    if (!isAdmin) {
      await assertCanSendToPhone(uid, phone);
    }

    const profileNameResolved =
      contactNameFromClient.length > 0
        ? contactNameFromClient
        : (await resolveContactProfileName(uid, phone));

    logger.info("[userSendWhatsapp] send", {
      uid,
      isAdmin,
      phone: `${phone.slice(0, 4)}…${phone.slice(-2)}`,
      messageLength: text.length,
    });

    try {
      const { messageId, usedTemplate } = await sendWhatsAppMessageOrTemplate(
        phone,
        text,
        {
          contactName: profileNameResolved ?? "",
        },
      );
      await persistOutboundCopy({
        conversationId: phone,
        phone,
        text,
        messageId,
        profileName: profileNameResolved,
      });
      return {
        success: true,
        messageId,
        status: "sent",
        usedTemplate: usedTemplate === true,
      };
    } catch (e: unknown) {
      const err = e as { message?: string; status?: number };
      logger.error("[userSendWhatsapp] Failed", {
        message: err.message,
        status: err.status,
      });
      const raw = (err.message || "WhatsApp send failed").toLowerCase();
      let friendly = err.message || "WhatsApp send failed";
      if (
        raw.includes("whatsapp config not found") ||
        raw.includes("whatsapp config missing")
      ) {
        friendly = "Please configure WhatsApp in settings";
      } else if (
        err.status === 401 ||
        raw.includes("invalid oauth") ||
        raw.includes("error validating access token") ||
        raw.includes("session has been invalidated")
      ) {
        friendly = "Invalid WhatsApp token, please update in settings";
      } else if (
        raw.includes("outboundtemplatename missing") ||
        raw.includes("131047") ||
        (raw.includes("template") && raw.includes("required"))
      ) {
        friendly =
          "WhatsApp ne free-text block kiya. Pehle Meta me approved template banao, phir app me WhatsApp settings → Outbound template name + language + body param count bharo.";
      }
      let code:
        | "invalid-argument"
        | "failed-precondition"
        | "permission-denied"
        | "not-found"
        | "internal" = "internal";
      if (err.message?.includes("format 91") || err.message?.includes("empty")) {
        code = "invalid-argument";
      } else if (err.status === 401) {
        code = "failed-precondition";
      } else if (err.status === 403) {
        code = "failed-precondition";
      } else if (err.status === 404) {
        code = "not-found";
      } else if (err.status && err.status >= 400 && err.status < 500) {
        code = "invalid-argument";
      }
      throw new HttpsError(code, friendly);
    }
  },
);

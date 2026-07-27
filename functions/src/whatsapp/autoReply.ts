/**
 * AIvy WhatsApp Auto-Reply Engine
 *
 * Handles keyword-based instant replies and provides a `generateAIReply`
 * placeholder that will be wired to an LLM (Gemini / GPT) in a future phase.
 *
 * Architecture:
 *   webhook POST → save message → onWhatsAppInboundMessageCreated trigger
 *     → triggerAutoReply() → generateAIReply() → sendWhatsAppMessage()
 *
 * To extend: add entries to KEYWORD_REPLIES or replace generateAIReply().
 */

import { logger } from "firebase-functions";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { withRetry } from "./retry";
import {
  recordSuccessfulWhatsAppSend,
  resolveWhatsAppCredentials,
} from "./credentials/resolver";

const GRAPH_VERSION = "v23.0";

// ---------------------------------------------------------------------------
// Keyword → reply map (case-insensitive, trimmed exact match)
// ---------------------------------------------------------------------------
const KEYWORD_REPLIES: Record<string, string> = {
  hi: "Hello 👋 Welcome to AIvy Assistant! How can I help you today?",
  hello: "Hello 👋 Welcome to AIvy Assistant! How can I help you today?",
  hey: "Hey there! 👋 I'm AIvy Assistant. Ask me anything!",
  help:
    "I can help you with:\n• Order status\n• Payment info\n• General queries\n\nJust type your question 🙂",
  start:
    "Hello 👋 Welcome to AIvy Assistant! How can I help you today?",
};

// ---------------------------------------------------------------------------
// AI reply placeholder — replace body with actual LLM call when ready
// ---------------------------------------------------------------------------
/**
 * Phase-2 placeholder for LLM-generated replies.
 *
 * @param message - The raw inbound text from the user.
 * @param context - Optional extra context (customer name, conversation history).
 * @returns The reply string, or null if the AI has no answer.
 */
export async function generateAIReply(
  message: string,
  context?: { customerName?: string | null; conversationId?: string },
): Promise<string | null> {
  // ── PHASE 1: keyword matching ──────────────────────────────────────────
  const normalized = message.trim().toLowerCase();
  if (Object.prototype.hasOwnProperty.call(KEYWORD_REPLIES, normalized)) {
    return KEYWORD_REPLIES[normalized];
  }

  // ── PHASE 2 (TODO): call Gemini / OpenAI ───────────────────────────────
  // Example when ready:
  //   const { GoogleGenerativeAI } = await import("@google/generative-ai");
  //   const genAI = new GoogleGenerativeAI(process.env.GEMINI_API_KEY ?? "");
  //   const model = genAI.getGenerativeModel({ model: "gemini-pro" });
  //   const chat = model.startChat({ history: [...contextHistory] });
  //   const result = await chat.sendMessage(message);
  //   return result.response.text();
  //
  // ── PHASE 3 (TODO): CRM-aware reply ────────────────────────────────────
  // Look up customer profile, open orders, due payments → personalised reply.

  logger.info("[autoReply] no AI reply generated (phase-2 not wired)", {
    conversationId: context?.conversationId,
  });
  return null;
}

// ---------------------------------------------------------------------------
// Internal: send via Meta Cloud API using Firestore config or .env fallback
// ---------------------------------------------------------------------------
async function sendAutoReply(to: string, text: string): Promise<string | null> {
  let resolved;
  try {
    resolved = await resolveWhatsAppCredentials({
      operation: "auto_reply",
    });
  } catch {
    logger.error("[autoReply] credentials missing — cannot send auto-reply");
    return null;
  }

  const token = resolved.token;
  const phoneId = resolved.phoneNumberId;

  if (!token || !phoneId) {
    logger.error("[autoReply] credentials missing — cannot send auto-reply");
    return null;
  }

  logger.info("[autoReply] using credentials", {
    credentialSource: resolved.credentialSource,
    connectionStatus: resolved.connectionStatus,
    phoneNumberId: resolved.phoneNumberId,
    wabaId: resolved.wabaId,
    fallbackReason: resolved.fallbackReason,
  });

  const url = `https://graph.facebook.com/${GRAPH_VERSION}/${phoneId}/messages`;
  const body = {
    messaging_product: "whatsapp",
    to,
    type: "text",
    text: { body: text, preview_url: false },
  };

  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  const raw = await res.text();
  if (!res.ok) {
    logger.error("[autoReply] Meta API error", {
      status: res.status,
      body: raw,
      to,
    });
    return null;
  }

  let parsed: Record<string, unknown> = {};
  try {
    parsed = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    // non-JSON response — still OK if status was 2xx
  }

  const messages = parsed.messages as Array<{ id?: string }> | undefined;
  const outboundMessageId = messages?.[0]?.id ?? null;
  if (outboundMessageId) {
    await recordSuccessfulWhatsAppSend({
      credentialSource: resolved.credentialSource,
      phoneNumberId: resolved.phoneNumberId,
      wabaId: resolved.wabaId,
      connectionStatus: resolved.connectionStatus,
      ownerUid: resolved.ownerUid,
      messageId: outboundMessageId,
    }).catch((e) => {
      logger.warn("[autoReply] migration dashboard update failed", {
        message: e instanceof Error ? e.message : String(e),
      });
    });
  }
  return outboundMessageId;
}

// ---------------------------------------------------------------------------
// Main entry-point called from the Firestore trigger
// ---------------------------------------------------------------------------
/**
 * Evaluate an inbound message for auto-reply eligibility.
 * - Skips if already replied, not text, or no reply generated.
 * - Sends reply via Meta Cloud API.
 * - Updates message doc + ai_inbox with reply metadata.
 * - Writes outbound message doc so it appears in the UI.
 */
export async function triggerAutoReply(opts: {
  conversationId: string;
  messageId: string;
  from: string;
  textBody: string | null;
  profileName: string | null;
}): Promise<void> {
  const { conversationId, messageId, from, textBody, profileName } = opts;

  // Only text messages with a non-empty body qualify
  if (!textBody || !textBody.trim()) {
    return;
  }

  // Check if this message was already processed
  const msgRef = getFirestore()
    .collection("whatsapp_conversations")
    .doc(conversationId)
    .collection("whatsapp_messages")
    .doc(messageId);

  const msgSnap = await withRetry("autoReply_readMsg", () => msgRef.get());
  const existing = msgSnap.data() ?? {};
  if (
    (existing.ai as Record<string, unknown> | undefined)?.autoReplySent === true
  ) {
    logger.info("[autoReply] already replied, skipping", { messageId });
    return;
  }

  // Generate reply text
  const replyText = await generateAIReply(textBody, {
    customerName: profileName,
    conversationId,
  });

  if (!replyText) {
    return;
  }

  // Send via Meta Cloud API
  const outboundMessageId = await sendAutoReply(from, replyText);
  const nowMs = Date.now();
  const nowSec = Math.floor(nowMs / 1000);

  logger.info("[autoReply] sent", {
    conversationId,
    messageId,
    outboundMessageId,
    to: from,
    replyLength: replyText.length,
  });

  // Persist outbound message + mark inbound as replied (in one batch)
  const db = getFirestore();
  const batch = db.batch();

  // Mark inbound message as auto-replied
  batch.set(
    msgRef,
    {
      ai: {
        queued: true,
        processed: true,
        autoReplySent: true,
        autoReplySentAt: FieldValue.serverTimestamp(),
        autoReplyMessageId: outboundMessageId ?? null,
      },
      updatedAt: FieldValue.serverTimestamp(),
      updatedAtMs: nowMs,
    },
    { merge: true },
  );

  // Write outbound message doc so it shows in the inbox UI
  if (outboundMessageId) {
    const outRef = db
      .collection("whatsapp_conversations")
      .doc(conversationId)
      .collection("whatsapp_messages")
      .doc(outboundMessageId);

    batch.set(outRef, {
      id: outboundMessageId,
      conversationId,
      from: "aivy_bot",
      direction: "outbound",
      type: "text",
      textBody: replyText,
      uiReadByAdmin: true,
      isAutoReply: true,
      status: {
        lastStatus: "sent",
        sentAtSec: nowSec,
        lastStatusAtSec: nowSec,
      },
      createdAt: FieldValue.serverTimestamp(),
      createdAtMs: nowMs,
      updatedAt: FieldValue.serverTimestamp(),
      updatedAtMs: nowMs,
    });

    // Write message index so status webhooks can resolve it
    batch.set(db.collection("whatsapp_message_index").doc(outboundMessageId), {
      messageId: outboundMessageId,
      conversationId,
      from,
      profileName: profileName ?? "Customer",
      lastStatus: "sent",
      lastStatusAtSec: nowSec,
      isAutoReply: true,
      updatedAt: FieldValue.serverTimestamp(),
      updatedAtMs: nowMs,
    });

    // Update conversation preview
    batch.set(
      db.collection("whatsapp_conversations").doc(conversationId),
      {
        lastMessageTextPreview: replyText.slice(0, 120),
        lastMessageType: "text",
        lastDirection: "outbound",
        lastDeliveryStatus: "sent",
        lastDeliveryStatusAtSec: nowSec,
        lastMessageAt: FieldValue.serverTimestamp(),
        lastMessageAtMs: nowMs,
        updatedAt: FieldValue.serverTimestamp(),
        updatedAtMs: nowMs,
      },
      { merge: true },
    );

    // Update AI inbox entry
    batch.set(
      db.collection("whatsapp_ai_inbox").doc(messageId),
      {
        status: "replied",
        autoReplyMessageId: outboundMessageId,
        repliedAt: FieldValue.serverTimestamp(),
        repliedAtMs: nowMs,
      },
      { merge: true },
    );
  }

  await withRetry("autoReply_batch", () => batch.commit());
}

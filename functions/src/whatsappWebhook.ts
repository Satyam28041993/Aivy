import { onRequest } from "firebase-functions/v2/https";
import { logger } from "firebase-functions";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import {
  readWhatsAppRuntimeConfig,
  readWhatsAppVerifyTokenOnly,
} from "./whatsapp/config";
import {
  verifyWebhookQueryToken,
  verifyWebhookSignature,
} from "./whatsapp/security";
import { processWhatsAppWebhookPayload } from "./whatsapp/service";
import { withRetry } from "./whatsapp/retry";
import { applyPendingStatusForMessageIndex } from "./whatsapp/repository";

const REGION = "us-central1";

export const whatsappWebhook = onRequest(
  { region: REGION, cors: false, invoker: "public" },
  async (req, res) => {
    const method = req.method.toUpperCase();

    if (method === "GET") {
      let verifyTokenExpected = "";
      try {
        verifyTokenExpected = await readWhatsAppVerifyTokenOnly();
      } catch (error) {
        logger.error("[whatsapp] verify-token read failed", {
          message: error instanceof Error ? error.message : String(error),
        });
        res.status(500).send("Configuration error");
        return;
      }
      const mode = String(req.query["hub.mode"] ?? "");
      const verifyToken = String(req.query["hub.verify_token"] ?? "");
      const challenge = String(req.query["hub.challenge"] ?? "");
      const check = verifyWebhookQueryToken(
        mode,
        verifyToken,
        challenge,
        verifyTokenExpected,
      );
      if (!check.ok || !check.challenge) {
        logger.warn("[whatsapp] verification failed", { mode });
        res.status(403).send("Forbidden");
        return;
      }
      logger.info("[whatsapp] verification success");
      res.status(200).send(check.challenge);
      return;
    }

    if (method !== "POST") {
      res.status(405).json({ error: "Method not allowed" });
      return;
    }

    let config;
    try {
      config = await readWhatsAppRuntimeConfig();
    } catch (error) {
      logger.error("[whatsapp] config read failed", {
        message: error instanceof Error ? error.message : String(error),
      });
      res.status(500).send("Configuration error");
      return;
    }

    const signature = req.header("x-hub-signature-256");
    const rawBody = Buffer.isBuffer(req.rawBody)
      ? req.rawBody
      : Buffer.from(JSON.stringify(req.body ?? {}), "utf8");
    const validSig = verifyWebhookSignature(rawBody, signature, config.appSecret);
    if (!validSig) {
      logger.warn("[whatsapp] invalid signature");
      res.status(403).json({ error: "Invalid signature" });
      return;
    }

    try {
      const result = await withRetry(
        "processWhatsAppWebhookPayload",
        async () => processWhatsAppWebhookPayload(req.body),
        { retries: 1, delayMs: 300 },
      );
      res.status(200).json({ ok: true, ...result });
    } catch (error) {
      logger.error("[whatsapp] webhook processing failed", {
        message: error instanceof Error ? error.message : String(error),
      });
      res.status(500).json({ ok: false, error: "Webhook processing failed" });
    }
  },
);

/**
 * AI processing foundation:
 * - captures inbound messages into an internal queue
 * - marks message as queued for future auto-reply orchestrator
 */
export const onWhatsAppInboundMessageCreated = onDocumentCreated(
  {
    region: REGION,
    document:
      "whatsapp_conversations/{conversationId}/whatsapp_messages/{messageId}",
    retry: true,
  },
  async (event) => {
    const data = event.data?.data();
    if (!data) {
      return;
    }
    const direction = String(data.direction ?? "").trim().toLowerCase();
    if (direction !== "inbound") {
      return;
    }
    const ai = (data.ai ?? {}) as { queued?: boolean; processed?: boolean };
    if (ai.processed === true) {
      return;
    }
    const conversationId = String(event.params.conversationId ?? "");
    const messageId = String(event.params.messageId ?? "");
    const nowMs = Date.now();

    await withRetry("queueInboundForAi", async () => {
      await getFirestore().runTransaction(async (tx) => {
        const queueRef = getFirestore()
          .collection("whatsapp_ai_inbox")
          .doc(messageId);
        const msgRef = getFirestore()
          .collection("whatsapp_conversations")
          .doc(conversationId)
          .collection("whatsapp_messages")
          .doc(messageId);
        const existing = await tx.get(queueRef);
        if (!existing.exists) {
          tx.set(queueRef, {
            id: messageId,
            conversationId,
            messageId,
            from: data.from ?? null,
            profileName: data.profileName ?? null,
            type: data.type ?? "unknown",
            textBody: data.textBody ?? null,
            media: data.media ?? null,
            status: "pending",
            source: "whatsapp_inbound",
            createdAt: FieldValue.serverTimestamp(),
            createdAtMs: nowMs,
          });
        }
        tx.set(
          msgRef,
          {
            ai: {
              queued: true,
              processed: false,
              autoReplyEligible: true,
            },
            aiQueuedAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
            updatedAtMs: nowMs,
          },
          { merge: true },
        );
      });
    });

    logger.info("[whatsapp] inbound queued for ai foundation", {
      conversationId,
      messageId,
    });
  },
);

export const onWhatsAppMessageIndexCreated = onDocumentCreated(
  {
    region: REGION,
    document: "whatsapp_message_index/{messageId}",
    retry: true,
  },
  async (event) => {
    const messageId = String(event.params.messageId ?? "").trim();
    if (!messageId) {
      return;
    }
    await applyPendingStatusForMessageIndex(messageId);
    logger.info("[whatsapp] flushed pending status for message index", {
      messageId,
    });
  },
);

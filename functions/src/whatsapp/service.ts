import { logger } from "firebase-functions";
import { parseWhatsAppWebhookBody } from "./parser";
import { applyStatusEvent, upsertInboundMessage } from "./repository";
import { triggerAutoReply } from "./autoReply";

export type WebhookProcessingSummary = {
  inboundSaved: number;
  statusUpdated: number;
  autoReplySent: number;
};

export async function processWhatsAppWebhookPayload(
  body: unknown,
): Promise<WebhookProcessingSummary> {
  const parsed = parseWhatsAppWebhookBody(body);
  let inboundSaved = 0;
  let statusUpdated = 0;
  let autoReplySent = 0;

  for (const msg of parsed.inboundMessages) {
    await upsertInboundMessage(msg);
    inboundSaved += 1;

    // Fire auto-reply for text messages; errors are caught so they don't
    // block the 200 OK response back to Meta.
    if (msg.type === "text" && msg.textBody) {
      try {
        await triggerAutoReply({
          conversationId: msg.conversationId,
          messageId: msg.messageId,
          from: msg.from,
          textBody: msg.textBody,
          profileName: msg.profileName,
        });
        autoReplySent += 1;
      } catch (err) {
        logger.error("[whatsapp] auto-reply failed", {
          messageId: msg.messageId,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }
  }

  for (const status of parsed.statusEvents) {
    await applyStatusEvent(status);
    statusUpdated += 1;
  }

  logger.info("[whatsapp] webhook payload processed", {
    inboundSaved,
    statusUpdated,
    autoReplySent,
  });
  return { inboundSaved, statusUpdated, autoReplySent };
}

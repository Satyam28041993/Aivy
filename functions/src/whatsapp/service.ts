import { logger } from "firebase-functions";
import { parseWhatsAppWebhookBody } from "./parser";
import { applyStatusEvent, upsertInboundMessage } from "./repository";
import { triggerAutoReply } from "./autoReply";
import { processCoexistenceWebhookEvents } from "./coexistence/processor";
import {
  detectCoexistenceParseWarnings,
  emptyParsedWebhookEvent,
} from "./coexistence/parseWarnings";
import type { CoexistenceProcessingSummary } from "./coexistence/types";

export type WebhookProcessingSummary = {
  inboundSaved: number;
  statusUpdated: number;
  autoReplySent: number;
  coexistence: CoexistenceProcessingSummary;
};
export async function processWhatsAppWebhookPayload(
  body: unknown,
): Promise<WebhookProcessingSummary> {
  let parsed = emptyParsedWebhookEvent();
  const parseErrors: string[] = [];
  try {
    parsed = parseWhatsAppWebhookBody(body);
    parseErrors.push(...detectCoexistenceParseWarnings(body, parsed));
  } catch (error) {
    parseErrors.push(
      error instanceof Error ? error.message : String(error),
    );
  }

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

  const coexistence = await processCoexistenceWebhookEvents({
    parsed,
    rawBody: body,
    parseErrors,
  });

  logger.info("[whatsapp] webhook payload processed", {
    inboundSaved,
    statusUpdated,
    autoReplySent,
    coexistenceStatus: coexistence.processingStatus,
  });
  return { inboundSaved, statusUpdated, autoReplySent, coexistence };
}
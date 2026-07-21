import type {
  ParsedInboundMessage,
  ParsedStatusEvent,
  ParsedWebhookEvent,
  WhatsAppDeliveryStatus,
  WhatsAppMessageType,
} from "./types";

function asRecord(v: unknown): Record<string, unknown> | null {
  return typeof v === "object" && v !== null && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : null;
}

function asArray(v: unknown): unknown[] {
  return Array.isArray(v) ? v : [];
}

function asString(v: unknown): string {
  return typeof v === "string" ? v : "";
}

function asNullableString(v: unknown): string | null {
  const s = asString(v).trim();
  return s.length > 0 ? s : null;
}

function asNullableNumber(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) {
    return v;
  }
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function normalizeMessageType(rawType: string): WhatsAppMessageType {
  if (rawType === "text" || rawType === "image" || rawType === "document" || rawType === "audio") {
    return rawType;
  }
  return "unknown";
}

function normalizeStatus(raw: string): WhatsAppDeliveryStatus {
  const s = raw.trim().toLowerCase();
  if (s === "sent" || s === "delivered" || s === "read" || s === "failed" || s === "warning") {
    return s;
  }
  return "unknown";
}

function parseMessage(
  message: Record<string, unknown>,
  fallbackFrom: string | null,
  profileName: string | null,
): ParsedInboundMessage | null {
  const messageId = asString(message.id).trim();
  if (!messageId) {
    return null;
  }
  const from = asString(message.from).trim() || fallbackFrom || "";
  if (!from) {
    return null;
  }
  const type = normalizeMessageType(asString(message.type).trim().toLowerCase());
  const textNode = asRecord(message.text);
  const imageNode = asRecord(message.image);
  const documentNode = asRecord(message.document);
  const audioNode = asRecord(message.audio);
  const conversationId = from;
  const timestampSec = asNullableNumber(message.timestamp);
  const textBody = asNullableString(textNode?.body);

  let media: ParsedInboundMessage["media"] = null;
  if (type === "image" && imageNode) {
    media = {
      id: asNullableString(imageNode.id),
      mimeType: asNullableString(imageNode.mime_type),
      sha256: asNullableString(imageNode.sha256),
      caption: asNullableString(imageNode.caption),
      filename: null,
    };
  } else if (type === "document" && documentNode) {
    media = {
      id: asNullableString(documentNode.id),
      mimeType: asNullableString(documentNode.mime_type),
      sha256: asNullableString(documentNode.sha256),
      caption: asNullableString(documentNode.caption),
      filename: asNullableString(documentNode.filename),
    };
  } else if (type === "audio" && audioNode) {
    media = {
      id: asNullableString(audioNode.id),
      mimeType: asNullableString(audioNode.mime_type),
      sha256: asNullableString(audioNode.sha256),
      caption: null,
      filename: null,
    };
  }

  return {
    messageId,
    conversationId,
    from,
    profileName,
    timestampSec,
    type,
    textBody,
    media,
    raw: message,
  };
}

function parseStatus(status: Record<string, unknown>): ParsedStatusEvent | null {
  const messageId = asString(status.id).trim();
  if (!messageId) {
    return null;
  }
  const conversation = asRecord(status.conversation);
  const pricing = asRecord(status.pricing);
  return {
    messageId,
    recipient: asNullableString(status.recipient_id),
    status: normalizeStatus(asString(status.status)),
    timestampSec: asNullableNumber(status.timestamp),
    conversationId: asNullableString(conversation?.id),
    pricingCategory: asNullableString(pricing?.category),
    raw: status,
  };
}

export function parseWhatsAppWebhookBody(body: unknown): ParsedWebhookEvent {
  const inboundMessages: ParsedInboundMessage[] = [];
  const statusEvents: ParsedStatusEvent[] = [];
  const root = asRecord(body);
  const entries = asArray(root?.entry);
  for (const entry of entries) {
    const entryNode = asRecord(entry);
    const changes = asArray(entryNode?.changes);
    for (const change of changes) {
      const changeNode = asRecord(change);
      const valueNode = asRecord(changeNode?.value);
      if (!valueNode) {
        continue;
      }
      const contacts = asArray(valueNode.contacts);
      const firstContact = asRecord(contacts[0]);
      const profile = asRecord(firstContact?.profile);
      const profileName = asNullableString(profile?.name);
      const contactWaId = asNullableString(firstContact?.wa_id);

      for (const m of asArray(valueNode.messages)) {
        const parsed = parseMessage(asRecord(m) ?? {}, contactWaId, profileName);
        if (parsed) {
          inboundMessages.push(parsed);
        }
      }
      for (const s of asArray(valueNode.statuses)) {
        const parsed = parseStatus(asRecord(s) ?? {});
        if (parsed) {
          statusEvents.push(parsed);
        }
      }
    }
  }
  return { inboundMessages, statusEvents };
}

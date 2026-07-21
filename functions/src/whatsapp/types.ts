export type WhatsAppMessageType = "text" | "image" | "document" | "audio" | "unknown";

export type WhatsAppDeliveryStatus =
  | "sent"
  | "delivered"
  | "read"
  | "failed"
  | "warning"
  | "unknown";

export type ParsedInboundMessage = {
  messageId: string;
  conversationId: string;
  from: string;
  profileName: string | null;
  timestampSec: number | null;
  type: WhatsAppMessageType;
  textBody: string | null;
  media: {
    id: string | null;
    mimeType: string | null;
    sha256: string | null;
    caption: string | null;
    filename: string | null;
  } | null;
  raw: Record<string, unknown>;
};

export type ParsedStatusEvent = {
  messageId: string;
  recipient: string | null;
  status: WhatsAppDeliveryStatus;
  timestampSec: number | null;
  conversationId: string | null;
  pricingCategory: string | null;
  raw: Record<string, unknown>;
};

export type ParsedWebhookEvent = {
  inboundMessages: ParsedInboundMessage[];
  statusEvents: ParsedStatusEvent[];
};

export type WhatsAppRuntimeConfig = {
  webhookVerifyToken: string;
  appSecret: string;
};

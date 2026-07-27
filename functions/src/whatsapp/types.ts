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

export type ParsedHistoryMessage = {
  messageId: string;
  threadId: string;
  from: string;
  to: string | null;
  conversationId: string;
  timestampSec: number | null;
  type: WhatsAppMessageType | "media_placeholder";
  textBody: string | null;
  historyStatus: string | null;
  media: ParsedInboundMessage["media"];
  raw: Record<string, unknown>;
};

export type ParsedHistoryError = {
  code: number | null;
  title: string | null;
  message: string | null;
  details: string | null;
  raw: Record<string, unknown>;
};

export type ParsedHistoryChunk = {
  phase: number | null;
  chunkOrder: number | null;
  progress: number | null;
  threads: Array<{
    threadId: string;
    messages: ParsedHistoryMessage[];
  }>;
  errors: ParsedHistoryError[];
  raw: Record<string, unknown>;
};

export type ParsedHistoryEvent = {
  wabaId: string | null;
  phoneNumberId: string | null;
  displayPhoneNumber: string | null;
  field: "history";
  chunks: ParsedHistoryChunk[];
  supplementalMessages: ParsedHistoryMessage[];
};

export type SmbContactSyncAction = "add" | "remove" | "unknown";

export type ParsedSmbContactSync = {
  syncType: string;
  action: SmbContactSyncAction;
  phoneNumber: string;
  fullName: string | null;
  firstName: string | null;
  timestampSec: number | null;
  raw: Record<string, unknown>;
};

export type ParsedSmbAppStateSyncEvent = {
  wabaId: string | null;
  phoneNumberId: string | null;
  displayPhoneNumber: string | null;
  field: "smb_app_state_sync";
  contacts: ParsedSmbContactSync[];
};

export type ParsedMessageEcho = {
  messageId: string;
  from: string;
  to: string;
  conversationId: string;
  timestampSec: number | null;
  type: WhatsAppMessageType;
  textBody: string | null;
  media: ParsedInboundMessage["media"];
  raw: Record<string, unknown>;
};

export type ParsedMessageEchoEvent = {
  wabaId: string | null;
  phoneNumberId: string | null;
  displayPhoneNumber: string | null;
  field: "smb_message_echoes";
  echoes: ParsedMessageEcho[];
};

export type ParsedWebhookEvent = {
  inboundMessages: ParsedInboundMessage[];
  statusEvents: ParsedStatusEvent[];
  historyEvents: ParsedHistoryEvent[];
  smbAppStateSyncEvents: ParsedSmbAppStateSyncEvent[];
  messageEchoEvents: ParsedMessageEchoEvent[];
};

export type WhatsAppRuntimeConfig = {
  webhookVerifyToken: string;
  appSecret: string;
};

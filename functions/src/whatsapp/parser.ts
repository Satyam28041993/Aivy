import type {

  ParsedHistoryChunk,

  ParsedHistoryError,

  ParsedHistoryEvent,

  ParsedHistoryMessage,

  ParsedInboundMessage,

  ParsedMessageEcho,

  ParsedMessageEchoEvent,

  ParsedSmbAppStateSyncEvent,

  ParsedSmbContactSync,

  ParsedStatusEvent,

  ParsedWebhookEvent,

  SmbContactSyncAction,

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



function normalizeHistoryMessageType(rawType: string): WhatsAppMessageType | "media_placeholder" {

  if (rawType === "media_placeholder") {

    return "media_placeholder";

  }

  return normalizeMessageType(rawType);

}



function normalizeStatus(raw: string): WhatsAppDeliveryStatus {

  const s = raw.trim().toLowerCase();

  if (s === "sent" || s === "delivered" || s === "read" || s === "failed" || s === "warning") {

    return s;

  }

  return "unknown";

}



function normalizeSmbContactAction(raw: string): SmbContactSyncAction {

  const s = raw.trim().toLowerCase();

  if (s === "add" || s === "remove") {

    return s;

  }

  return "unknown";

}



function extractMedia(

  type: WhatsAppMessageType,

  message: Record<string, unknown>,

): ParsedInboundMessage["media"] {

  const imageNode = asRecord(message.image);

  const documentNode = asRecord(message.document);

  const audioNode = asRecord(message.audio);



  if (type === "image" && imageNode) {

    return {

      id: asNullableString(imageNode.id),

      mimeType: asNullableString(imageNode.mime_type),

      sha256: asNullableString(imageNode.sha256),

      caption: asNullableString(imageNode.caption),

      filename: null,

    };

  }

  if (type === "document" && documentNode) {

    return {

      id: asNullableString(documentNode.id),

      mimeType: asNullableString(documentNode.mime_type),

      sha256: asNullableString(documentNode.sha256),

      caption: asNullableString(documentNode.caption),

      filename: asNullableString(documentNode.filename),

    };

  }

  if (type === "audio" && audioNode) {

    return {

      id: asNullableString(audioNode.id),

      mimeType: asNullableString(audioNode.mime_type),

      sha256: asNullableString(audioNode.sha256),

      caption: null,

      filename: null,

    };

  }

  return null;

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

  const conversationId = from;

  const timestampSec = asNullableNumber(message.timestamp);

  const textBody = asNullableString(textNode?.body);



  return {

    messageId,

    conversationId,

    from,

    profileName,

    timestampSec,

    type,

    textBody,

    media: extractMedia(type, message),

    raw: message,

  };

}



function parseHistoryMessage(

  message: Record<string, unknown>,

  threadId: string,

): ParsedHistoryMessage | null {

  const messageId = asString(message.id).trim();

  if (!messageId) {

    return null;

  }

  const from = asString(message.from).trim();

  if (!from) {

    return null;

  }

  const to = asNullableString(message.to);

  const type = normalizeHistoryMessageType(asString(message.type).trim().toLowerCase());

  const textNode = asRecord(message.text);

  const historyContext = asRecord(message.history_context);

  const conversationId = threadId.trim() || to || from;



  return {

    messageId,

    threadId,

    from,

    to,

    conversationId,

    timestampSec: asNullableNumber(message.timestamp),

    type,

    textBody: asNullableString(textNode?.body),

    historyStatus: asNullableString(historyContext?.status),

    media: type === "media_placeholder" ? null : extractMedia(type, message),

    raw: message,

  };

}



function parseHistoryError(errorNode: Record<string, unknown>): ParsedHistoryError {

  const errorData = asRecord(errorNode.error_data);

  return {

    code: asNullableNumber(errorNode.code),

    title: asNullableString(errorNode.title),

    message: asNullableString(errorNode.message),

    details: asNullableString(errorData?.details),

    raw: errorNode,

  };

}



function parseHistoryChunk(chunkNode: Record<string, unknown>): ParsedHistoryChunk {

  const chunkMeta = asRecord(chunkNode.metadata);

  const threads: ParsedHistoryChunk["threads"] = [];



  for (const thread of asArray(chunkNode.threads)) {

    const threadNode = asRecord(thread) ?? {};

    const threadId = asString(threadNode.id).trim();

    const messages: ParsedHistoryMessage[] = [];

    for (const m of asArray(threadNode.messages)) {

      const parsed = parseHistoryMessage(asRecord(m) ?? {}, threadId);

      if (parsed) {

        messages.push(parsed);

      }

    }

    if (threadId || messages.length > 0) {

      threads.push({ threadId, messages });

    }

  }



  const errors: ParsedHistoryError[] = [];

  for (const e of asArray(chunkNode.errors)) {

    errors.push(parseHistoryError(asRecord(e) ?? {}));

  }



  return {

    phase: asNullableNumber(chunkMeta?.phase),

    chunkOrder: asNullableNumber(chunkMeta?.chunk_order),

    progress: asNullableNumber(chunkMeta?.progress),

    threads,

    errors,

    raw: chunkNode,

  };

}



function parseValueMetadata(valueNode: Record<string, unknown>): {

  phoneNumberId: string | null;

  displayPhoneNumber: string | null;

} {

  const metadata = asRecord(valueNode.metadata);

  return {

    phoneNumberId: asNullableString(metadata?.phone_number_id),

    displayPhoneNumber: asNullableString(metadata?.display_phone_number),

  };

}



function parseHistoryEvent(

  valueNode: Record<string, unknown>,

  wabaId: string | null,

  changeField: string,

): ParsedHistoryEvent | null {

  const hasHistory = asArray(valueNode.history).length > 0;

  const supplementalMessages: ParsedHistoryMessage[] = [];

  const isHistoryField = changeField.trim().toLowerCase() === "history";



  if (isHistoryField) {

    for (const m of asArray(valueNode.messages)) {

      const parsed = parseHistoryMessage(asRecord(m) ?? {}, asString(asRecord(m)?.from).trim());

      if (parsed) {

        supplementalMessages.push(parsed);

      }

    }

  }



  if (!hasHistory && supplementalMessages.length === 0) {

    return null;

  }



  const chunks: ParsedHistoryChunk[] = [];

  for (const chunk of asArray(valueNode.history)) {

    chunks.push(parseHistoryChunk(asRecord(chunk) ?? {}));

  }



  const { phoneNumberId, displayPhoneNumber } = parseValueMetadata(valueNode);

  return {

    wabaId,

    phoneNumberId,

    displayPhoneNumber,

    field: "history",

    chunks,

    supplementalMessages,

  };

}



function parseSmbContactSync(node: Record<string, unknown>): ParsedSmbContactSync | null {

  const syncType = asString(node.type).trim().toLowerCase() || "contact";

  const action = normalizeSmbContactAction(asString(node.action));

  const contact = asRecord(node.contact) ?? {};

  const syncMeta = asRecord(node.metadata);

  const phoneNumber = asString(contact.phone_number).trim();

  if (!phoneNumber) {

    return null;

  }

  return {

    syncType,

    action,

    phoneNumber,

    fullName: asNullableString(contact.full_name),

    firstName: asNullableString(contact.first_name),

    timestampSec: asNullableNumber(syncMeta?.timestamp),

    raw: node,

  };

}



function parseSmbAppStateSyncEvent(

  valueNode: Record<string, unknown>,

  wabaId: string | null,

): ParsedSmbAppStateSyncEvent | null {

  const contacts: ParsedSmbContactSync[] = [];

  for (const item of asArray(valueNode.state_sync)) {

    const parsed = parseSmbContactSync(asRecord(item) ?? {});

    if (parsed) {

      contacts.push(parsed);

    }

  }

  if (contacts.length === 0) {

    return null;

  }

  const { phoneNumberId, displayPhoneNumber } = parseValueMetadata(valueNode);

  return {

    wabaId,

    phoneNumberId,

    displayPhoneNumber,

    field: "smb_app_state_sync",

    contacts,

  };

}



function parseMessageEcho(message: Record<string, unknown>): ParsedMessageEcho | null {

  const messageId = asString(message.id).trim();

  const from = asString(message.from).trim();

  const to = asString(message.to).trim();

  if (!messageId || !from || !to) {

    return null;

  }

  const type = normalizeMessageType(asString(message.type).trim().toLowerCase());

  const textNode = asRecord(message.text);

  return {

    messageId,

    from,

    to,

    conversationId: to,

    timestampSec: asNullableNumber(message.timestamp),

    type,

    textBody: asNullableString(textNode?.body),

    media: extractMedia(type, message),

    raw: message,

  };

}



function parseMessageEchoEvent(

  valueNode: Record<string, unknown>,

  wabaId: string | null,

): ParsedMessageEchoEvent | null {

  const echoes: ParsedMessageEcho[] = [];

  for (const echo of asArray(valueNode.message_echoes)) {

    const parsed = parseMessageEcho(asRecord(echo) ?? {});

    if (parsed) {

      echoes.push(parsed);

    }

  }

  if (echoes.length === 0) {

    return null;

  }

  const { phoneNumberId, displayPhoneNumber } = parseValueMetadata(valueNode);

  return {

    wabaId,

    phoneNumberId,

    displayPhoneNumber,

    field: "smb_message_echoes",

    echoes,

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

  const historyEvents: ParsedHistoryEvent[] = [];

  const smbAppStateSyncEvents: ParsedSmbAppStateSyncEvent[] = [];

  const messageEchoEvents: ParsedMessageEchoEvent[] = [];



  const root = asRecord(body);

  const entries = asArray(root?.entry);

  for (const entry of entries) {

    const entryNode = asRecord(entry);

    const wabaId = asNullableString(entryNode?.id);

    const changes = asArray(entryNode?.changes);

    for (const change of changes) {

      const changeNode = asRecord(change);

      const valueNode = asRecord(changeNode?.value);

      if (!valueNode) {

        continue;

      }

      const changeField = asString(changeNode?.field).trim().toLowerCase();



      const contacts = asArray(valueNode.contacts);

      const firstContact = asRecord(contacts[0]);

      const profile = asRecord(firstContact?.profile);

      const profileName = asNullableString(profile?.name);

      const contactWaId = asNullableString(firstContact?.wa_id);



      for (const m of asArray(valueNode.messages)) {

        if (changeField === "history") {

          continue;

        }

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



      const historyEvent = parseHistoryEvent(valueNode, wabaId, changeField);

      if (historyEvent) {

        historyEvents.push(historyEvent);

      }



      const smbSyncEvent = parseSmbAppStateSyncEvent(valueNode, wabaId);

      if (smbSyncEvent) {

        smbAppStateSyncEvents.push(smbSyncEvent);

      }



      const echoEvent = parseMessageEchoEvent(valueNode, wabaId);

      if (echoEvent) {

        messageEchoEvents.push(echoEvent);

      }

    }

  }

  return {

    inboundMessages,

    statusEvents,

    historyEvents,

    smbAppStateSyncEvents,

    messageEchoEvents,

  };

}



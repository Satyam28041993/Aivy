import { logger } from "firebase-functions";
import type {
  ParsedHistoryEvent,
  ParsedMessageEchoEvent,
  ParsedSmbAppStateSyncEvent,
} from "../types";
import {
  historyChunkRecordId,
  historySupplementalRecordId,
  hashWebhookPayload,
  messageEchoRecordId,
  smbSyncRecordId,
} from "./idempotency";
import { createFirestoreCoexistenceStore } from "./store";
import type {
  CoexistenceEventType,
  CoexistenceProcessingSummary,
  CoexistenceProcessInput,
  CoexistenceStore,
  CoexistenceUpsertResult,
} from "./types";

function logCoexistenceEvent(opts: {
  eventType: CoexistenceEventType;
  wabaId: string | null;
  phoneNumberId: string | null;
  timestampMs: number;
  eventCount: number;
  processingStatus: string;
  recordId?: string;
  created?: boolean;
  duplicate?: boolean;
}): void {
  logger.info("[whatsapp-coexistence] webhook_event", {
    eventType: opts.eventType,
    wabaId: opts.wabaId,
    phoneNumberId: opts.phoneNumberId,
    timestamp: opts.timestampMs,
    eventCount: opts.eventCount,
    processingStatus: opts.processingStatus,
    recordId: opts.recordId ?? null,
    created: opts.created ?? null,
    duplicate: opts.duplicate ?? null,
  });
}

async function persistHistoryEvent(
  store: CoexistenceStore,
  event: ParsedHistoryEvent,
  webhookPayloadHash: string,
): Promise<{
  created: number;
  duplicates: number;
  lastRecordId: string | null;
}> {
  let created = 0;
  let duplicates = 0;
  let lastRecordId: string | null = null;
  const timestampMs = Date.now();

  for (let chunkIndex = 0; chunkIndex < event.chunks.length; chunkIndex++) {
    const chunk = event.chunks[chunkIndex];
    const errorCode = chunk.errors[0]?.code ?? null;
    const recordId = historyChunkRecordId({
      wabaId: event.wabaId,
      phoneNumberId: event.phoneNumberId,
      phase: chunk.phase,
      chunkOrder: chunk.chunkOrder,
      chunkIndex,
      errorCode,
    });
    const result = await store.upsertHistoryRecord(recordId, {
      wabaId: event.wabaId,
      phoneNumberId: event.phoneNumberId,
      displayPhoneNumber: event.displayPhoneNumber,
      field: event.field,
      chunk,
      webhookPayloadHash,
    });
    if (result.created) {
      created += 1;
    } else if (result.duplicate) {
      duplicates += 1;
    }
    lastRecordId = recordId;
    logCoexistenceEvent({
      eventType: "history",
      wabaId: event.wabaId,
      phoneNumberId: event.phoneNumberId,
      timestampMs,
      eventCount: chunk.threads.length + chunk.errors.length,
      processingStatus: result.duplicate ? "duplicate_ignored" : "stored",
      recordId,
      created: result.created,
      duplicate: result.duplicate,
    });
  }

  for (const message of event.supplementalMessages) {
    const recordId = historySupplementalRecordId(message.messageId);
    const result = await store.upsertHistoryRecord(recordId, {
      wabaId: event.wabaId,
      phoneNumberId: event.phoneNumberId,
      displayPhoneNumber: event.displayPhoneNumber,
      field: event.field,
      supplementalMessage: message,
      webhookPayloadHash,
    });
    if (result.created) {
      created += 1;
    } else if (result.duplicate) {
      duplicates += 1;
    }
    lastRecordId = recordId;
    logCoexistenceEvent({
      eventType: "history",
      wabaId: event.wabaId,
      phoneNumberId: event.phoneNumberId,
      timestampMs,
      eventCount: 1,
      processingStatus: result.duplicate ? "duplicate_ignored" : "stored",
      recordId,
      created: result.created,
      duplicate: result.duplicate,
    });
  }

  return { created, duplicates, lastRecordId };
}

async function persistSmbSyncEvent(
  store: CoexistenceStore,
  event: ParsedSmbAppStateSyncEvent,
  webhookPayloadHash: string,
): Promise<{
  created: number;
  duplicates: number;
  lastRecordId: string | null;
}> {
  let created = 0;
  let duplicates = 0;
  let lastRecordId: string | null = null;
  const timestampMs = Date.now();

  for (let syncIndex = 0; syncIndex < event.contacts.length; syncIndex++) {
    const contact = event.contacts[syncIndex];
    const recordId = smbSyncRecordId({
      wabaId: event.wabaId,
      phoneNumber: contact.phoneNumber,
      action: contact.action,
      timestampSec: contact.timestampSec,
      syncIndex,
    });
    const result = await store.upsertSmbSyncRecord(recordId, {
      wabaId: event.wabaId,
      phoneNumberId: event.phoneNumberId,
      displayPhoneNumber: event.displayPhoneNumber,
      field: event.field,
      contact,
      webhookPayloadHash,
    });
    if (result.created) {
      created += 1;
    } else if (result.duplicate) {
      duplicates += 1;
    }
    lastRecordId = recordId;
    logCoexistenceEvent({
      eventType: "smb_app_state_sync",
      wabaId: event.wabaId,
      phoneNumberId: event.phoneNumberId,
      timestampMs,
      eventCount: 1,
      processingStatus: result.duplicate ? "duplicate_ignored" : "stored",
      recordId,
      created: result.created,
      duplicate: result.duplicate,
    });
  }

  return { created, duplicates, lastRecordId };
}

async function persistEchoEvent(
  store: CoexistenceStore,
  event: ParsedMessageEchoEvent,
  webhookPayloadHash: string,
): Promise<{
  created: number;
  duplicates: number;
  lastRecordId: string | null;
}> {
  let created = 0;
  let duplicates = 0;
  let lastRecordId: string | null = null;
  const timestampMs = Date.now();

  for (const echo of event.echoes) {
    const recordId = messageEchoRecordId(echo.messageId);
    const result = await store.upsertEchoRecord(recordId, {
      wabaId: event.wabaId,
      phoneNumberId: event.phoneNumberId,
      displayPhoneNumber: event.displayPhoneNumber,
      field: event.field,
      echo,
      webhookPayloadHash,
    });
    if (result.created) {
      created += 1;
    } else if (result.duplicate) {
      duplicates += 1;
    }
    lastRecordId = recordId;
    logCoexistenceEvent({
      eventType: "smb_message_echoes",
      wabaId: event.wabaId,
      phoneNumberId: event.phoneNumberId,
      timestampMs,
      eventCount: 1,
      processingStatus: result.duplicate ? "duplicate_ignored" : "stored",
      recordId,
      created: result.created,
      duplicate: result.duplicate,
    });
  }

  return { created, duplicates, lastRecordId };
}

function resolveProcessingStatus(
  summary: Omit<CoexistenceProcessingSummary, "processingStatus" | "parseErrors">,
  parseErrors: string[],
): CoexistenceProcessingSummary["processingStatus"] {
  if (parseErrors.length > 0) {
    const anyStored =
      summary.historyRecordsCreated +
        summary.smbSyncRecordsCreated +
        summary.echoRecordsCreated >
      0;
    return anyStored ? "partial_error" : "parse_error";
  }
  const anyRecords =
    summary.historyRecordsCreated +
      summary.smbSyncRecordsCreated +
      summary.echoRecordsCreated +
      summary.historyDuplicatesSkipped +
      summary.smbSyncDuplicatesSkipped +
      summary.echoDuplicatesSkipped >
    0;
  return anyRecords ? "stored" : "skipped_empty";
}

export async function processCoexistenceWebhookEvents(
  input: CoexistenceProcessInput,
  store: CoexistenceStore = createFirestoreCoexistenceStore(),
): Promise<CoexistenceProcessingSummary> {
  const parseErrors = [...(input.parseErrors ?? [])];
  const webhookPayloadHash = hashWebhookPayload(input.rawBody);
  const parsed = input.parsed;

  let historyRecordsCreated = 0;
  let historyDuplicatesSkipped = 0;
  let smbSyncRecordsCreated = 0;
  let smbSyncDuplicatesSkipped = 0;
  let echoRecordsCreated = 0;
  let echoDuplicatesSkipped = 0;

  let lastHistoryRecordId: string | null = null;
  let lastSmbSyncRecordId: string | null = null;
  let lastEchoRecordId: string | null = null;
  let lastHistoryWabaId: string | null = null;
  let lastHistoryPhoneNumberId: string | null = null;
  let lastSmbWabaId: string | null = null;
  let lastSmbPhoneNumberId: string | null = null;
  let lastEchoWabaId: string | null = null;
  let lastEchoPhoneNumberId: string | null = null;

  for (const event of parsed.historyEvents) {
    lastHistoryWabaId = event.wabaId;
    lastHistoryPhoneNumberId = event.phoneNumberId;
    const result = await persistHistoryEvent(store, event, webhookPayloadHash);
    historyRecordsCreated += result.created;
    historyDuplicatesSkipped += result.duplicates;
    lastHistoryRecordId = result.lastRecordId;
  }

  for (const event of parsed.smbAppStateSyncEvents) {
    lastSmbWabaId = event.wabaId;
    lastSmbPhoneNumberId = event.phoneNumberId;
    const result = await persistSmbSyncEvent(store, event, webhookPayloadHash);
    smbSyncRecordsCreated += result.created;
    smbSyncDuplicatesSkipped += result.duplicates;
    lastSmbSyncRecordId = result.lastRecordId;
  }

  for (const event of parsed.messageEchoEvents) {
    lastEchoWabaId = event.wabaId;
    lastEchoPhoneNumberId = event.phoneNumberId;
    const result = await persistEchoEvent(store, event, webhookPayloadHash);
    echoRecordsCreated += result.created;
    echoDuplicatesSkipped += result.duplicates;
    lastEchoRecordId = result.lastRecordId;
  }

  const partialSummary = {
    historyRecordsCreated,
    historyDuplicatesSkipped,
    smbSyncRecordsCreated,
    smbSyncDuplicatesSkipped,
    echoRecordsCreated,
    echoDuplicatesSkipped,
  };
  const processingStatus = resolveProcessingStatus(partialSummary, parseErrors);
  const nowMs = Date.now();

  await store.updateDiagnostics({
    lastWebhookPayloadHash: webhookPayloadHash,
    lastWebhookProcessedAtMs: nowMs,
    lastProcessingStatus: processingStatus,
    lastParseErrors: parseErrors,
    lastHistory: lastHistoryRecordId
      ? {
          recordId: lastHistoryRecordId,
          wabaId: lastHistoryWabaId,
          phoneNumberId: lastHistoryPhoneNumberId,
          processedAtMs: nowMs,
          status: processingStatus,
        }
      : null,
    lastSmbAppStateSync: lastSmbSyncRecordId
      ? {
          recordId: lastSmbSyncRecordId,
          wabaId: lastSmbWabaId,
          phoneNumberId: lastSmbPhoneNumberId,
          processedAtMs: nowMs,
          status: processingStatus,
        }
      : null,
    lastMessageEcho: lastEchoRecordId
      ? {
          recordId: lastEchoRecordId,
          wabaId: lastEchoWabaId,
          phoneNumberId: lastEchoPhoneNumberId,
          processedAtMs: nowMs,
          status: processingStatus,
        }
      : null,
    totals: {
      historyRecordsCreated,
      historyDuplicatesSkipped,
      smbSyncRecordsCreated,
      smbSyncDuplicatesSkipped,
      echoRecordsCreated,
      echoDuplicatesSkipped,
    },
  });

  logger.info("[whatsapp-coexistence] batch_complete", {
    eventType: "coexistence_batch",
    wabaId: lastHistoryWabaId ?? lastSmbWabaId ?? lastEchoWabaId,
    phoneNumberId:
      lastHistoryPhoneNumberId ?? lastSmbPhoneNumberId ?? lastEchoPhoneNumberId,
    timestamp: nowMs,
    eventCount:
      parsed.historyEvents.length +
      parsed.smbAppStateSyncEvents.length +
      parsed.messageEchoEvents.length,
    processingStatus,
    ...partialSummary,
    parseErrorCount: parseErrors.length,
  });

  return {
    ...partialSummary,
    parseErrors,
    processingStatus,
  };
}

export type { CoexistenceUpsertResult };

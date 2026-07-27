import type {
  ParsedHistoryEvent,
  ParsedMessageEchoEvent,
  ParsedSmbAppStateSyncEvent,
  ParsedWebhookEvent,
} from "../types";

export type CoexistenceEventType =
  | "history"
  | "smb_app_state_sync"
  | "smb_message_echoes";

export type CoexistenceProcessingStatus =
  | "stored"
  | "duplicate_ignored"
  | "skipped_empty"
  | "parse_error"
  | "partial_error";

export type CoexistenceUpsertResult = {
  recordId: string;
  eventType: CoexistenceEventType;
  created: boolean;
  duplicate: boolean;
};

export type CoexistenceProcessingSummary = {
  historyRecordsCreated: number;
  historyDuplicatesSkipped: number;
  smbSyncRecordsCreated: number;
  smbSyncDuplicatesSkipped: number;
  echoRecordsCreated: number;
  echoDuplicatesSkipped: number;
  parseErrors: string[];
  processingStatus: CoexistenceProcessingStatus;
};

export type CoexistenceStore = {
  upsertHistoryRecord(
    recordId: string,
    payload: Record<string, unknown>,
  ): Promise<CoexistenceUpsertResult>;
  upsertSmbSyncRecord(
    recordId: string,
    payload: Record<string, unknown>,
  ): Promise<CoexistenceUpsertResult>;
  upsertEchoRecord(
    recordId: string,
    payload: Record<string, unknown>,
  ): Promise<CoexistenceUpsertResult>;
  updateDiagnostics(patch: Record<string, unknown>): Promise<void>;
};

export type CoexistenceProcessInput = {
  parsed: ParsedWebhookEvent;
  rawBody: unknown;
  parseErrors?: string[];
};

export type ParsedCoexistenceBatch = {
  historyEvents: ParsedHistoryEvent[];
  smbAppStateSyncEvents: ParsedSmbAppStateSyncEvent[];
  messageEchoEvents: ParsedMessageEchoEvent[];
};

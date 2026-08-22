import type { ParsedWebhookEvent } from "../types";

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

function countRawCoexistenceFields(rawBody: unknown): {
  historyChanges: number;
  smbSyncChanges: number;
  echoChanges: number;
} {
  let historyChanges = 0;
  let smbSyncChanges = 0;
  let echoChanges = 0;
  const root = asRecord(rawBody);
  for (const entry of asArray(root?.entry)) {
    const entryNode = asRecord(entry);
    for (const change of asArray(entryNode?.changes)) {
      const changeNode = asRecord(change);
      const field = asString(changeNode?.field).trim().toLowerCase();
      if (field === "history") {
        historyChanges += 1;
      } else if (field === "smb_app_state_sync") {
        smbSyncChanges += 1;
      } else if (field === "smb_message_echoes") {
        echoChanges += 1;
      }
    }
  }
  return { historyChanges, smbSyncChanges, echoChanges };
}

export function detectCoexistenceParseWarnings(
  rawBody: unknown,
  parsed: ParsedWebhookEvent,
): string[] {
  const warnings: string[] = [];
  const rawCounts = countRawCoexistenceFields(rawBody);

  if (rawCounts.historyChanges > 0 && parsed.historyEvents.length === 0) {
    warnings.push(
      `history field present (${rawCounts.historyChanges} change(s)) but parser produced 0 historyEvents`,
    );
  }
  if (rawCounts.smbSyncChanges > 0 && parsed.smbAppStateSyncEvents.length === 0) {
    warnings.push(
      `smb_app_state_sync field present (${rawCounts.smbSyncChanges} change(s)) but parser produced 0 smbAppStateSyncEvents`,
    );
  }
  if (rawCounts.echoChanges > 0 && parsed.messageEchoEvents.length === 0) {
    warnings.push(
      `smb_message_echoes field present (${rawCounts.echoChanges} change(s)) but parser produced 0 messageEchoEvents`,
    );
  }

  return warnings;
}

export function emptyParsedWebhookEvent(): ParsedWebhookEvent {
  return {
    inboundMessages: [],
    statusEvents: [],
    historyEvents: [],
    smbAppStateSyncEvents: [],
    messageEchoEvents: [],
  };
}

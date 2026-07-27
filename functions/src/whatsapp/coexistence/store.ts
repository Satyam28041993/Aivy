import { FieldValue, getFirestore } from "firebase-admin/firestore";
import type { CoexistenceEventType, CoexistenceStore, CoexistenceUpsertResult } from "./types";

const HISTORY_COLLECTION = "whatsapp_coexistence_history";
const SMB_SYNC_COLLECTION = "whatsapp_coexistence_app_state_sync";
const ECHO_COLLECTION = "whatsapp_coexistence_message_echoes";
const DIAGNOSTICS_DOC = "whatsapp_coexistence_diagnostics/summary";

function collectionForEventType(eventType: CoexistenceEventType): string {
  switch (eventType) {
    case "history":
      return HISTORY_COLLECTION;
    case "smb_app_state_sync":
      return SMB_SYNC_COLLECTION;
    case "smb_message_echoes":
      return ECHO_COLLECTION;
  }
}

async function upsertIdempotentRecord(
  eventType: CoexistenceEventType,
  recordId: string,
  payload: Record<string, unknown>,
): Promise<CoexistenceUpsertResult> {
  const db = getFirestore();
  const ref = db.collection(collectionForEventType(eventType)).doc(recordId);
  const nowMs = Date.now();

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (snap.exists) {
      tx.set(
        ref,
        {
          lastSeenAt: FieldValue.serverTimestamp(),
          lastSeenAtMs: nowMs,
          deliveryCount: FieldValue.increment(1),
          processingStatus: "duplicate_ignored",
        },
        { merge: true },
      );
      return {
        recordId,
        eventType,
        created: false,
        duplicate: true,
      };
    }

    tx.set(ref, {
      ...payload,
      id: recordId,
      idempotencyKey: recordId,
      eventType,
      createdAt: FieldValue.serverTimestamp(),
      createdAtMs: nowMs,
      lastSeenAt: FieldValue.serverTimestamp(),
      lastSeenAtMs: nowMs,
      deliveryCount: 1,
      processingStatus: "stored",
    });
    return {
      recordId,
      eventType,
      created: true,
      duplicate: false,
    };
  });
}

export function createFirestoreCoexistenceStore(): CoexistenceStore {
  return {
    upsertHistoryRecord(recordId, payload) {
      return upsertIdempotentRecord("history", recordId, payload);
    },
    upsertSmbSyncRecord(recordId, payload) {
      return upsertIdempotentRecord("smb_app_state_sync", recordId, payload);
    },
    upsertEchoRecord(recordId, payload) {
      return upsertIdempotentRecord("smb_message_echoes", recordId, payload);
    },
    async updateDiagnostics(patch) {
      const db = getFirestore();
      await db.doc(DIAGNOSTICS_DOC).set(
        {
          ...patch,
          updatedAt: FieldValue.serverTimestamp(),
          updatedAtMs: Date.now(),
        },
        { merge: true },
      );
    },
  };
}

export const COEXISTENCE_COLLECTIONS = {
  history: HISTORY_COLLECTION,
  smbSync: SMB_SYNC_COLLECTION,
  echoes: ECHO_COLLECTION,
  diagnosticsDoc: DIAGNOSTICS_DOC,
} as const;

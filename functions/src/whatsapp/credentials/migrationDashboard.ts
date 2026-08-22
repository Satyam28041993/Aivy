import { FieldValue, getFirestore } from "firebase-admin/firestore";
import type { CredentialSource, ResolvedWhatsAppCredentials } from "./types";

export const MIGRATION_DASHBOARD_DOC = "whatsapp_migration_diagnostics/summary";

export async function updateMigrationDashboard(
  patch: Record<string, unknown>,
): Promise<void> {
  await getFirestore()
    .doc(MIGRATION_DASHBOARD_DOC)
    .set(
      {
        ...patch,
        updatedAt: FieldValue.serverTimestamp(),
        updatedAtMs: Date.now(),
      },
      { merge: true },
    );
}

export async function recordCredentialResolution(
  resolved: ResolvedWhatsAppCredentials,
  operation: string,
): Promise<void> {
  await updateMigrationDashboard({
    currentCredentialSource: resolved.credentialSource,
    connectionStatus: resolved.connectionStatus,
    secretStatus: resolved.secretStatus,
    phoneNumberId: resolved.phoneNumberId,
    wabaId: resolved.wabaId,
    fallbackReason: resolved.fallbackReason,
    useMetaCoexistenceFlag: resolved.useMetaCoexistenceFlag,
    ownerUid: resolved.ownerUid,
    lastResolvedAtMs: Date.now(),
    lastOperation: operation,
  });
}

export async function recordSuccessfulWhatsAppSend(opts: {
  credentialSource: CredentialSource;
  phoneNumberId: string;
  wabaId: string | null;
  connectionStatus: string | null;
  ownerUid: string | null;
  messageId: string;
}): Promise<void> {
  await updateMigrationDashboard({
    lastSuccessfulSend: {
      messageId: opts.messageId,
      credentialSource: opts.credentialSource,
      phoneNumberId: opts.phoneNumberId,
      wabaId: opts.wabaId,
      connectionStatus: opts.connectionStatus,
      ownerUid: opts.ownerUid,
      atMs: Date.now(),
    },
    currentCredentialSource: opts.credentialSource,
    connectionStatus: opts.connectionStatus,
    phoneNumberId: opts.phoneNumberId,
    wabaId: opts.wabaId,
  });
}

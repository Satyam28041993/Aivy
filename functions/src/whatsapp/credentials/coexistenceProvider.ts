import { readWhatsappConnectionMetadata } from "../onboarding/connectionStore";
import { readBusinessTokenSecret } from "../onboarding/tokenStorage";
import type { CoexistenceValidationResult } from "./types";
import { parseOutboundTemplateFields } from "./templateConfig";

function isConnectedStatus(status: string): boolean {
  return status.trim().toLowerCase() === "connected";
}

export async function validateCoexistenceCredentials(
  ownerUid: string,
): Promise<CoexistenceValidationResult> {
  const metadata = await readWhatsappConnectionMetadata(ownerUid);
  if (!metadata) {
    return {
      ok: false,
      reason: "missing_metadata",
      secretStatus: "not_applicable",
      connectionStatus: null,
      wabaId: null,
      phoneNumberId: null,
      tokenSecretRef: null,
    };
  }

  const connectionStatus = metadata.connectionStatus;
  const phoneNumberId = metadata.phoneNumberId;
  const wabaId = metadata.wabaId;
  const tokenSecretRef = metadata.tokenSecretRef;

  if (!isConnectedStatus(connectionStatus)) {
    return {
      ok: false,
      reason: "connection_not_connected",
      secretStatus: "not_applicable",
      connectionStatus,
      wabaId,
      phoneNumberId,
      tokenSecretRef,
    };
  }

  if (!phoneNumberId) {
    return {
      ok: false,
      reason: "missing_phone_number_id",
      secretStatus: "not_applicable",
      connectionStatus,
      wabaId,
      phoneNumberId: null,
      tokenSecretRef,
    };
  }

  if (!tokenSecretRef) {
    return {
      ok: false,
      reason: "missing_secret_ref",
      secretStatus: "missing_ref",
      connectionStatus,
      wabaId,
      phoneNumberId,
      tokenSecretRef: null,
    };
  }

  let token = "";
  try {
    token = await readBusinessTokenSecret(tokenSecretRef);
  } catch {
    return {
      ok: false,
      reason: "secret_read_failed",
      secretStatus: "read_failed",
      connectionStatus,
      wabaId,
      phoneNumberId,
      tokenSecretRef,
    };
  }

  if (!token || token.length <= 50) {
    return {
      ok: false,
      reason: "invalid_secret_token",
      secretStatus: "invalid_token",
      connectionStatus,
      wabaId,
      phoneNumberId,
      tokenSecretRef,
    };
  }

  return {
    ok: true,
    metadata: {
      wabaId,
      phoneNumberId,
      connectionStatus,
      tokenSecretRef,
      displayPhoneNumber: metadata.displayPhoneNumber,
      token,
      ...parseOutboundTemplateFields(metadata as unknown as Record<string, unknown>),
    },
    secretStatus: "ok",
  };
}

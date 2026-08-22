import { describe, expect, it, vi, beforeEach } from "vitest";
import { resolveWhatsAppCredentials } from "./resolver";
import type {
  CoexistenceValidationResult,
  CredentialResolverDeps,
} from "./types";

const validCoexistence: CoexistenceValidationResult = {
  ok: true,
  metadata: {
    wabaId: "WABA_NEW",
    phoneNumberId: "PHONE_NEW",
    connectionStatus: "connected",
    tokenSecretRef: "projects/p/secrets/s/versions/1",
    displayPhoneNumber: "15550783881",
    token: "META_TOKEN_" + "y".repeat(60),
    outboundTemplateName: "coexistence_tpl",
    outboundTemplateLanguage: "hi",
    outboundTemplateBodyParamCount: 1,
  },
  secretStatus: "ok",
};

function createDeps(
  overrides: Partial<CredentialResolverDeps> = {},
): CredentialResolverDeps {
  const readLegacyConfig = vi.fn(async () => {
    throw new Error("legacy doc must not be read");
  });

  return {
    useMetaCoexistence: () => true,
    readLegacyConfig,
    validateCoexistence: async () => validCoexistence,
    resolveDefaultOwnerUid: async () => "owner_uid_12345678",
    updateMigrationDashboard: async () => {},
    ...overrides,
  };
}

describe("zero legacy read regression", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("valid coexistence works even when app_config/whatsapp does not exist", async () => {
    const readLegacyConfig = vi.fn(async () => null);
    const deps = createDeps({ readLegacyConfig });

    const resolved = await resolveWhatsAppCredentials(
      { ownerUid: "owner_uid_12345678", operation: "send" },
      deps,
    );

    expect(resolved.credentialSource).toBe("META_COEXISTENCE");
    expect(resolved.phoneNumberId).toBe("PHONE_NEW");
    expect(readLegacyConfig).not.toHaveBeenCalled();
  });

  it("legacy fallback still works when the feature flag is OFF", async () => {
    const readLegacyConfig = vi.fn(async () => ({
      token: "LEGACY_TOKEN_" + "x".repeat(60),
      phoneId: "LEGACY_PHONE_ID",
      outboundTemplateName: "hello_world",
      outboundTemplateLanguage: "en",
      outboundTemplateBodyParamCount: 1,
      contactsOwnerUid: "owner_uid_12345678",
      raw: {},
    }));

    const resolved = await resolveWhatsAppCredentials(
      { ownerUid: "owner_uid_12345678" },
      {
        useMetaCoexistence: () => false,
        readLegacyConfig,
        validateCoexistence: async () => validCoexistence,
        resolveDefaultOwnerUid: async () => "owner_uid_12345678",
        updateMigrationDashboard: async () => {},
      },
    );

    expect(resolved.credentialSource).toBe("LEGACY");
    expect(readLegacyConfig).toHaveBeenCalledTimes(1);
  });

  it("resolver never reads legacy during successful coexistence mode", async () => {
    const readLegacyConfig = vi.fn(async () => null);
    const deps = createDeps({ readLegacyConfig });

    await resolveWhatsAppCredentials(
      { ownerUid: "owner_uid_12345678", operation: "health_check" },
      deps,
    );

    expect(readLegacyConfig).not.toHaveBeenCalled();
  });

  it("reads legacy only on explicit migration fallback when coexistence validation fails", async () => {
    const readLegacyConfig = vi.fn(async () => ({
      token: "LEGACY_TOKEN_" + "x".repeat(60),
      phoneId: "LEGACY_PHONE_ID",
      outboundTemplateName: "hello_world",
      outboundTemplateLanguage: "en",
      outboundTemplateBodyParamCount: 1,
      contactsOwnerUid: "owner_uid_12345678",
      raw: {},
    }));

    const resolved = await resolveWhatsAppCredentials(
      { ownerUid: "owner_uid_12345678" },
      {
        useMetaCoexistence: () => true,
        readLegacyConfig,
        validateCoexistence: async () => ({
          ok: false,
          reason: "missing_metadata",
          secretStatus: "not_applicable",
          connectionStatus: null,
          wabaId: null,
          phoneNumberId: null,
          tokenSecretRef: null,
        }),
        resolveDefaultOwnerUid: async () => "owner_uid_12345678",
        updateMigrationDashboard: async () => {},
      },
    );

    expect(resolved.credentialSource).toBe("LEGACY");
    expect(resolved.fallbackReason).toBe("missing_metadata");
    expect(readLegacyConfig).toHaveBeenCalledTimes(1);
  });
});

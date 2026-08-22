import { describe, expect, it, vi, beforeEach } from "vitest";
import { resolveWhatsAppCredentials } from "./resolver";
import type {
  CoexistenceValidationResult,
  CredentialResolverDeps,
  LegacyWhatsAppConfig,
} from "./types";

const legacyConfig: LegacyWhatsAppConfig = {
  token: "LEGACY_TOKEN_" + "x".repeat(60),
  phoneId: "LEGACY_PHONE_ID",
  outboundTemplateName: "hello_world",
  outboundTemplateLanguage: "en",
  outboundTemplateBodyParamCount: 1,
  contactsOwnerUid: "owner_uid_12345678",
  raw: {},
};

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
  return {
    useMetaCoexistence: () => false,
    readLegacyConfig: async () => legacyConfig,
    validateCoexistence: async () => validCoexistence,
    resolveDefaultOwnerUid: async () => "owner_uid_12345678",
    updateMigrationDashboard: async () => {},
    ...overrides,
  };
}

describe("resolveWhatsAppCredentials", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("uses legacy credentials when feature flag is OFF (legacy only)", async () => {
    const resolved = await resolveWhatsAppCredentials(
      { ownerUid: "owner_uid_12345678", operation: "test" },
      createDeps({ useMetaCoexistence: () => false }),
    );

    expect(resolved.credentialSource).toBe("LEGACY");
    expect(resolved.phoneNumberId).toBe("LEGACY_PHONE_ID");
    expect(resolved.fallbackReason).toBeNull();
    expect(resolved.useMetaCoexistenceFlag).toBe(false);
  });

  it("uses coexistence credentials when feature flag is ON and validation passes (new only)", async () => {
    const resolved = await resolveWhatsAppCredentials(
      { ownerUid: "owner_uid_12345678", operation: "test" },
      createDeps({ useMetaCoexistence: () => true }),
    );

    expect(resolved.credentialSource).toBe("META_COEXISTENCE");
    expect(resolved.phoneNumberId).toBe("PHONE_NEW");
    expect(resolved.wabaId).toBe("WABA_NEW");
    expect(resolved.fallbackReason).toBeNull();
    expect(resolved.secretStatus).toBe("ok");
    expect(resolved.outboundTemplateName).toBe("coexistence_tpl");
    expect(resolved.templateSource).toBe("COEXISTENCE");
  });

  it("falls back to legacy when secret reference is missing", async () => {
    const resolved = await resolveWhatsAppCredentials(
      { ownerUid: "owner_uid_12345678" },
      createDeps({
        useMetaCoexistence: () => true,
        validateCoexistence: async () => ({
          ok: false,
          reason: "missing_secret_ref",
          secretStatus: "missing_ref",
          connectionStatus: "connected",
          wabaId: "WABA_NEW",
          phoneNumberId: "PHONE_NEW",
          tokenSecretRef: null,
        }),
      }),
    );

    expect(resolved.credentialSource).toBe("LEGACY");
    expect(resolved.fallbackReason).toBe("missing_secret_ref");
    expect(resolved.secretStatus).toBe("missing_ref");
  });

  it("falls back to legacy when metadata is missing", async () => {
    const resolved = await resolveWhatsAppCredentials(
      { ownerUid: "owner_uid_12345678" },
      createDeps({
        useMetaCoexistence: () => true,
        validateCoexistence: async () => ({
          ok: false,
          reason: "missing_metadata",
          secretStatus: "not_applicable",
          connectionStatus: null,
          wabaId: null,
          phoneNumberId: null,
          tokenSecretRef: null,
        }),
      }),
    );

    expect(resolved.credentialSource).toBe("LEGACY");
    expect(resolved.fallbackReason).toBe("missing_metadata");
  });

  it("falls back to legacy when Secret Manager token is invalid", async () => {
    const resolved = await resolveWhatsAppCredentials(
      { ownerUid: "owner_uid_12345678" },
      createDeps({
        useMetaCoexistence: () => true,
        validateCoexistence: async () => ({
          ok: false,
          reason: "invalid_secret_token",
          secretStatus: "invalid_token",
          connectionStatus: "connected",
          wabaId: "WABA_NEW",
          phoneNumberId: "PHONE_NEW",
          tokenSecretRef: "projects/p/secrets/s/versions/1",
        }),
      }),
    );

    expect(resolved.credentialSource).toBe("LEGACY");
    expect(resolved.fallbackReason).toBe("invalid_secret_token");
    expect(resolved.secretStatus).toBe("invalid_token");
  });

  it("falls back to legacy when connection status is not connected", async () => {
    const resolved = await resolveWhatsAppCredentials(
      { ownerUid: "owner_uid_12345678" },
      createDeps({
        useMetaCoexistence: () => true,
        validateCoexistence: async () => ({
          ok: false,
          reason: "connection_not_connected",
          secretStatus: "not_applicable",
          connectionStatus: "pending",
          wabaId: "WABA_NEW",
          phoneNumberId: "PHONE_NEW",
          tokenSecretRef: "projects/p/secrets/s/versions/1",
        }),
      }),
    );

    expect(resolved.credentialSource).toBe("LEGACY");
    expect(resolved.fallbackReason).toBe("connection_not_connected");
  });

  it("falls back to legacy when owner uid is missing under coexistence flag", async () => {
    const resolved = await resolveWhatsAppCredentials(
      { ownerUid: null },
      createDeps({
        useMetaCoexistence: () => true,
        resolveDefaultOwnerUid: async () => null,
      }),
    );

    expect(resolved.credentialSource).toBe("LEGACY");
    expect(resolved.fallbackReason).toBe("missing_owner_uid");
  });

  it("throws only when legacy credentials are unavailable", async () => {
    await expect(
      resolveWhatsAppCredentials(
        {},
        createDeps({ readLegacyConfig: async () => null }),
      ),
    ).rejects.toThrow("WhatsApp config missing");
  });

  it("records migration dashboard fields on resolution", async () => {
    const dashboardUpdates: Record<string, unknown>[] = [];
    await resolveWhatsAppCredentials(
      { ownerUid: "owner_uid_12345678", operation: "send" },
      createDeps({
        useMetaCoexistence: () => true,
        updateMigrationDashboard: async (patch) => {
          dashboardUpdates.push(patch);
        },
      }),
    );

    expect(dashboardUpdates.length).toBeGreaterThan(0);
    const last = dashboardUpdates[dashboardUpdates.length - 1];
    expect(last.currentCredentialSource).toBe("META_COEXISTENCE");
    expect(last.connectionStatus).toBe("connected");
    expect(last.phoneNumberId).toBe("PHONE_NEW");
    expect(last.wabaId).toBe("WABA_NEW");
    expect(last.fallbackReason).toBeNull();
  });
});

describe("validateCoexistenceCredentials integration", () => {
  it("accepts connected status case-insensitively", async () => {
    const { validateCoexistenceCredentials } = await import("./coexistenceProvider");
    const connectionStore = await import("../onboarding/connectionStore");
    const tokenStorage = await import("../onboarding/tokenStorage");

    vi.spyOn(connectionStore, "readWhatsappConnectionMetadata").mockResolvedValue({
      ownerUid: "owner_uid_12345678",
      wabaId: "WABA_NEW",
      phoneNumberId: "PHONE_NEW",
      displayPhoneNumber: "15550783881",
      connectionStatus: "connected",
      historySyncStatus: "pending",
      coexistenceEnabled: true,
      tokenSecretRef: "projects/p/secrets/s/versions/1",
      onboardedAtMs: Date.now(),
      outboundTemplateName: "coexistence_tpl",
      outboundTemplateLanguage: "en",
      outboundTemplateBodyParamCount: 1,
      contactsOwnerUid: "owner_uid_12345678",
    });
    vi.spyOn(tokenStorage, "readBusinessTokenSecret").mockResolvedValue(
      "META_TOKEN_" + "z".repeat(60),
    );

    const result = await validateCoexistenceCredentials("owner_uid_12345678");
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.metadata.phoneNumberId).toBe("PHONE_NEW");
    }
  });
});

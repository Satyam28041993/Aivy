export type CredentialSource = "META_COEXISTENCE" | "LEGACY";

export type LegacyWhatsAppConfig = {
  token: string;
  phoneId: string;
  outboundTemplateName: string;
  outboundTemplateLanguage: string;
  outboundTemplateBodyParamCount: number;
  contactsOwnerUid: string | null;
  raw: Record<string, unknown>;
};

export type ResolvedWhatsAppCredentials = {
  token: string;
  phoneNumberId: string;
  credentialSource: CredentialSource;
  connectionStatus: string | null;
  wabaId: string | null;
  tokenSecretRef: string | null;
  ownerUid: string | null;
  fallbackReason: string | null;
  secretStatus: "ok" | "missing_ref" | "read_failed" | "invalid_token" | "not_applicable";
  useMetaCoexistenceFlag: boolean;
  outboundTemplateName: string;
  outboundTemplateLanguage: string;
  outboundTemplateBodyParamCount: number;
  templateSource: "COEXISTENCE" | "LEGACY";
};

export type ResolveCredentialsOptions = {
  ownerUid?: string | null;
  operation?: string;
};

export type CoexistenceValidationResult =
  | {
      ok: true;
      metadata: {
        wabaId: string;
        phoneNumberId: string;
        connectionStatus: string;
        tokenSecretRef: string;
        displayPhoneNumber: string;
        token: string;
        outboundTemplateName: string;
        outboundTemplateLanguage: string;
        outboundTemplateBodyParamCount: number;
      };
      secretStatus: "ok";
    }
  | {
      ok: false;
      reason: string;
      secretStatus: "missing_ref" | "read_failed" | "invalid_token" | "not_applicable";
      connectionStatus: string | null;
      wabaId: string | null;
      phoneNumberId: string | null;
      tokenSecretRef: string | null;
    };

export type CredentialResolverDeps = {
  useMetaCoexistence: () => boolean;
  readLegacyConfig: () => Promise<LegacyWhatsAppConfig | null>;
  validateCoexistence: (ownerUid: string) => Promise<CoexistenceValidationResult>;
  resolveDefaultOwnerUid: (options?: {
    ownerUid?: string | null;
    phoneNumberId?: string | null;
    allowLegacyFallback?: boolean;
  }) => Promise<string | null>;
  updateMigrationDashboard: (patch: Record<string, unknown>) => Promise<void>;
};

import { logger } from "firebase-functions";

import { validateCoexistenceCredentials } from "./coexistenceProvider";

import { readLegacyWhatsAppConfig } from "./legacyProvider";

import {

  updateMigrationDashboard,

} from "./migrationDashboard";

import { resolveDefaultOwnerUid } from "./ownerProvider";

import { parseOutboundTemplateFields } from "./templateConfig";

import type {

  CoexistenceValidationResult,

  CredentialResolverDeps,

  LegacyWhatsAppConfig,

  ResolveCredentialsOptions,

  ResolvedWhatsAppCredentials,

} from "./types";



export function isMetaCoexistenceEnabled(): boolean {

  return String(process.env.USE_META_COEXISTENCE ?? "")

    .trim()

    .toLowerCase() === "true";

}



function buildLegacyResolved(

  legacy: LegacyWhatsAppConfig,

  ownerUid: string | null,

  useMetaCoexistenceFlag: boolean,

  fallbackReason: string | null,

): ResolvedWhatsAppCredentials {

  return {

    token: legacy.token,

    phoneNumberId: legacy.phoneId,

    credentialSource: "LEGACY",

    connectionStatus: null,

    wabaId: null,

    tokenSecretRef: null,

    ownerUid,

    fallbackReason,

    secretStatus: "not_applicable",

    useMetaCoexistenceFlag,

    outboundTemplateName: legacy.outboundTemplateName,

    outboundTemplateLanguage: legacy.outboundTemplateLanguage,

    outboundTemplateBodyParamCount: legacy.outboundTemplateBodyParamCount,

    templateSource: "LEGACY",

  };

}



function buildCoexistenceResolved(

  validated: Extract<CoexistenceValidationResult, { ok: true }>,

  ownerUid: string,

): ResolvedWhatsAppCredentials {

  const templates = parseOutboundTemplateFields({

    outboundTemplateName: validated.metadata.outboundTemplateName,

    outboundTemplateLanguage: validated.metadata.outboundTemplateLanguage,

    outboundTemplateBodyParamCount: validated.metadata.outboundTemplateBodyParamCount,

  });

  return {

    token: validated.metadata.token,

    phoneNumberId: validated.metadata.phoneNumberId,

    credentialSource: "META_COEXISTENCE",

    connectionStatus: validated.metadata.connectionStatus,

    wabaId: validated.metadata.wabaId,

    tokenSecretRef: validated.metadata.tokenSecretRef,

    ownerUid,

    fallbackReason: null,

    secretStatus: "ok",

    useMetaCoexistenceFlag: true,

    outboundTemplateName: templates.outboundTemplateName,

    outboundTemplateLanguage: templates.outboundTemplateLanguage,

    outboundTemplateBodyParamCount: templates.outboundTemplateBodyParamCount,

    templateSource: "COEXISTENCE",

  };

}



function publishCredentialResolution(

  deps: CredentialResolverDeps,

  resolved: ResolvedWhatsAppCredentials,

  operation: string,

): Promise<void> {

  return deps.updateMigrationDashboard({

    currentCredentialSource: resolved.credentialSource,

    connectionStatus: resolved.connectionStatus,

    secretStatus: resolved.secretStatus,

    phoneNumberId: resolved.phoneNumberId,

    wabaId: resolved.wabaId,

    fallbackReason: resolved.fallbackReason,

    useMetaCoexistenceFlag: resolved.useMetaCoexistenceFlag,

    ownerUid: resolved.ownerUid,

    templateSource: resolved.templateSource,

    lastResolvedAtMs: Date.now(),

    lastOperation: operation,

  });

}



function logCredentialResolution(

  resolved: ResolvedWhatsAppCredentials,

  operation: string,

): void {

  logger.info("[whatsapp-credentials] resolved", {

    operation,

    credentialSource: resolved.credentialSource,

    connectionStatus: resolved.connectionStatus,

    phoneNumberId: resolved.phoneNumberId,

    wabaId: resolved.wabaId,

    fallbackReason: resolved.fallbackReason,

    secretStatus: resolved.secretStatus,

    ownerUid: resolved.ownerUid,

    useMetaCoexistenceFlag: resolved.useMetaCoexistenceFlag,

    templateSource: resolved.templateSource,

  });

}



export function createDefaultCredentialResolverDeps(): CredentialResolverDeps {

  return {

    useMetaCoexistence: isMetaCoexistenceEnabled,

    readLegacyConfig: readLegacyWhatsAppConfig,

    validateCoexistence: validateCoexistenceCredentials,

    resolveDefaultOwnerUid: (options) => resolveDefaultOwnerUid(options),

    updateMigrationDashboard,

  };

}



export async function resolveWhatsAppCredentials(

  options: ResolveCredentialsOptions = {},

  deps: CredentialResolverDeps = createDefaultCredentialResolverDeps(),

): Promise<ResolvedWhatsAppCredentials> {

  const operation = String(options.operation ?? "send").trim() || "send";

  const useMetaCoexistenceFlag = deps.useMetaCoexistence();

  const explicitOwnerUid = String(options.ownerUid ?? "").trim();

  const ownerUid =

    explicitOwnerUid.length > 8

      ? explicitOwnerUid

      : await deps.resolveDefaultOwnerUid({

          allowLegacyFallback: !useMetaCoexistenceFlag,

        });



  if (!useMetaCoexistenceFlag) {

    const legacy = await deps.readLegacyConfig();

    if (!legacy) {

      await deps.updateMigrationDashboard({

        lastError: "legacy_credentials_unavailable",

        lastResolvedAtMs: Date.now(),

        lastOperation: operation,

      });

      throw new Error("WhatsApp config missing");

    }

    const resolved = buildLegacyResolved(legacy, ownerUid, false, null);

    logCredentialResolution(resolved, operation);

    await publishCredentialResolution(deps, resolved, operation);

    return resolved;

  }



  if (!ownerUid) {

    const legacy = await deps.readLegacyConfig();

    if (!legacy) {

      await deps.updateMigrationDashboard({

        lastError: "legacy_credentials_unavailable",

        lastResolvedAtMs: Date.now(),

        lastOperation: operation,

        fallbackReason: "missing_owner_uid",

      });

      throw new Error("WhatsApp config missing");

    }

    const resolved = buildLegacyResolved(

      legacy,

      null,

      true,

      "missing_owner_uid",

    );

    logCredentialResolution(resolved, operation);

    await publishCredentialResolution(deps, resolved, operation);

    return resolved;

  }



  const validated = await deps.validateCoexistence(ownerUid);

  if (validated.ok) {

    const resolved = buildCoexistenceResolved(validated, ownerUid);

    logCredentialResolution(resolved, operation);

    await publishCredentialResolution(deps, resolved, operation);

    return resolved;

  }



  const legacy = await deps.readLegacyConfig();

  if (!legacy) {

    await deps.updateMigrationDashboard({

      lastError: "legacy_credentials_unavailable",

      lastResolvedAtMs: Date.now(),

      lastOperation: operation,

      fallbackReason: validated.reason,

    });

    throw new Error("WhatsApp config missing");

  }



  const resolved = buildLegacyResolved(

    legacy,

    ownerUid,

    true,

    validated.reason,

  );

  resolved.connectionStatus = validated.connectionStatus;

  resolved.wabaId = validated.wabaId;

  resolved.tokenSecretRef = validated.tokenSecretRef;

  resolved.secretStatus = validated.secretStatus;

  logCredentialResolution(resolved, operation);

  await publishCredentialResolution(deps, resolved, operation);

  return resolved;

}



export {

  recordCredentialResolution,

  recordSuccessfulWhatsAppSend,

  updateMigrationDashboard,

} from "./migrationDashboard";



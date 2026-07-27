export type OutboundTemplateConfig = {
  outboundTemplateName: string;
  outboundTemplateLanguage: string;
  outboundTemplateBodyParamCount: number;
};

export function parseOutboundTemplateFields(
  data: Record<string, unknown>,
): OutboundTemplateConfig {
  let paramCount = Number(data.outboundTemplateBodyParamCount);
  if (!Number.isFinite(paramCount)) {
    paramCount = 0;
  }
  return {
    outboundTemplateName: String(data.outboundTemplateName ?? "").trim(),
    outboundTemplateLanguage:
      String(data.outboundTemplateLanguage ?? "en").trim() || "en",
    outboundTemplateBodyParamCount: Math.min(
      3,
      Math.max(0, Math.floor(paramCount)),
    ),
  };
}

export function resolveOutboundTemplates(opts: {
  coexistence: OutboundTemplateConfig;
  legacy: OutboundTemplateConfig;
  credentialSource: "META_COEXISTENCE" | "LEGACY";
}): OutboundTemplateConfig & { templateSource: "COEXISTENCE" | "LEGACY" } {
  if (opts.credentialSource === "META_COEXISTENCE") {
    if (opts.coexistence.outboundTemplateName) {
      return { ...opts.coexistence, templateSource: "COEXISTENCE" };
    }
    if (opts.legacy.outboundTemplateName) {
      return { ...opts.legacy, templateSource: "LEGACY" };
    }
    return { ...opts.coexistence, templateSource: "COEXISTENCE" };
  }
  return { ...opts.legacy, templateSource: "LEGACY" };
}

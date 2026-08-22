import { describe, expect, it } from "vitest";
import {
  parseOutboundTemplateFields,
  resolveOutboundTemplates,
} from "./templateConfig";

describe("templateConfig", () => {
  it("parses template fields with defaults", () => {
    const parsed = parseOutboundTemplateFields({
      outboundTemplateName: "hello_world",
      outboundTemplateLanguage: "",
      outboundTemplateBodyParamCount: 2.9,
    });
    expect(parsed.outboundTemplateName).toBe("hello_world");
    expect(parsed.outboundTemplateLanguage).toBe("en");
    expect(parsed.outboundTemplateBodyParamCount).toBe(2);
  });

  it("prefers coexistence templates when credential source is META_COEXISTENCE", () => {
    const resolved = resolveOutboundTemplates({
      credentialSource: "META_COEXISTENCE",
      coexistence: {
        outboundTemplateName: "coexistence_tpl",
        outboundTemplateLanguage: "hi",
        outboundTemplateBodyParamCount: 1,
      },
      legacy: {
        outboundTemplateName: "legacy_tpl",
        outboundTemplateLanguage: "en",
        outboundTemplateBodyParamCount: 0,
      },
    });
    expect(resolved.templateSource).toBe("COEXISTENCE");
    expect(resolved.outboundTemplateName).toBe("coexistence_tpl");
  });

  it("falls back to legacy templates when coexistence template name is empty", () => {
    const resolved = resolveOutboundTemplates({
      credentialSource: "META_COEXISTENCE",
      coexistence: {
        outboundTemplateName: "",
        outboundTemplateLanguage: "en",
        outboundTemplateBodyParamCount: 0,
      },
      legacy: {
        outboundTemplateName: "legacy_tpl",
        outboundTemplateLanguage: "en",
        outboundTemplateBodyParamCount: 1,
      },
    });
    expect(resolved.templateSource).toBe("LEGACY");
    expect(resolved.outboundTemplateName).toBe("legacy_tpl");
  });
});

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");

describe("outbound path credential resolver audit", () => {
  it("whatsappService send paths resolve credentials through loadSendConfig", () => {
    const src = readFileSync(join(root, "services/whatsappService.js"), "utf8");
    expect(src).toContain("resolveWhatsAppCredentials");
    expect(src).toContain("loadSendConfig");
    expect(src).toContain("async function sendOnce(");
    expect(src).toMatch(/sendOnce\([\s\S]*loadSendConfig/);
    expect(src).not.toMatch(/async function sendOnce[\s\S]*getWhatsAppConfig\(/);
  });

  it("autoReply resolves credentials through resolveWhatsAppCredentials", () => {
    const src = readFileSync(join(root, "src/whatsapp/autoReply.ts"), "utf8");
    expect(src).toContain("resolveWhatsAppCredentials");
    expect(src).not.toContain('collection("app_config").doc("whatsapp")');
  });

  it("userSendWhatsapp passes ownerUid into sendWhatsAppMessageOrTemplate", () => {
    const src = readFileSync(join(root, "src/userSendWhatsapp.ts"), "utf8");
    expect(src).toContain("ownerUid: uid");
    expect(src).toContain("sendWhatsAppMessageOrTemplate");
  });

  it("testWhatsapp passes ownerUid into sendWhatsAppMessageOrTemplate", () => {
    const src = readFileSync(join(root, "src/testWhatsappApi.ts"), "utf8");
    expect(src).toContain("ownerUid: request.auth.uid");
    expect(src).toContain("sendWhatsAppMessageOrTemplate");
  });

  it("checkWhatsappHealth resolves credentials through resolveWhatsAppCredentials", () => {
    const src = readFileSync(join(root, "src/checkWhatsappHealth.ts"), "utf8");
    expect(src).toContain("resolveWhatsAppCredentials");
    expect(src).not.toContain('collection("app_config").doc("whatsapp")');
  });
});

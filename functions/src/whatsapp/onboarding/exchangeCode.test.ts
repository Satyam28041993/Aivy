import { describe, expect, it, vi, afterEach } from "vitest";
import { exchangeEmbeddedSignupCode } from "./exchangeCode";

describe("exchangeEmbeddedSignupCode", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("returns access token on success", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        ok: true,
        text: async () =>
          JSON.stringify({
            access_token: "EAAB-test-token",
            token_type: "bearer",
            expires_in: 5184000,
          }),
      })),
    );

    const result = await exchangeEmbeddedSignupCode({
      code: "oauth-code-123",
      appId: "1138403541782773",
      appSecret: "secret",
    });

    expect(result.accessToken).toBe("EAAB-test-token");
    expect(result.tokenType).toBe("bearer");
    expect(result.expiresInSec).toBe(5184000);
  });

  it("throws when Meta returns an error", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        ok: false,
        status: 400,
        text: async () =>
          JSON.stringify({ error: { message: "Invalid authorization code" } }),
      })),
    );

    await expect(
      exchangeEmbeddedSignupCode({
        code: "bad-code",
        appId: "1138403541782773",
        appSecret: "secret",
      }),
    ).rejects.toThrow("Invalid authorization code");
  });
});

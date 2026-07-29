import { logger } from "firebase-functions";
import { HttpsError } from "firebase-functions/v2/https";
import type { ExchangeCodeResult } from "./types";

const DEFAULT_GRAPH_VERSION = "v21.0";

/**
 * Exchanges an Embedded Signup authorization code for a business access token.
 *
 * The code comes from the Facebook JS SDK `FB.login` with
 * `override_default_response_type: true`, so per Meta's Embedded Signup spec the
 * exchange is done WITHOUT a redirect_uri. If Meta returns error_subcode 36008
 * ("Error validating verification code ... redirect_uri"), it means Meta did not
 * honour override_default_response_type and the code stayed bound to the SDK's
 * internal (xd_arbiter) redirect — this happens when the app is not yet fully
 * provisioned (Live mode + Advanced Access for whatsapp_business_management).
 * See docs/whatsapp-embedded-signup-go-live.md.
 */
export async function exchangeEmbeddedSignupCode(opts: {
  code: string;
  redirectUri?: string;
  appId: string;
  appSecret: string;
  graphApiVersion?: string;
}): Promise<ExchangeCodeResult> {
  const code = String(opts.code ?? "").trim();
  const appId = String(opts.appId ?? "").trim();
  const appSecret = String(opts.appSecret ?? "").trim();
  const graphApiVersion =
    String(opts.graphApiVersion ?? DEFAULT_GRAPH_VERSION).trim() || DEFAULT_GRAPH_VERSION;

  if (!code) {
    throw new HttpsError("invalid-argument", "OAuth code is required");
  }
  if (!appId || !appSecret) {
    throw new HttpsError("failed-precondition", "Meta app credentials are not configured");
  }

  // If code is already a Meta user access token (starts with EAA...)
  if (code.startsWith("EAA")) {
    const exchangeUrl = new URL(`https://graph.facebook.com/${graphApiVersion}/oauth/access_token`);
    exchangeUrl.searchParams.set("grant_type", "fb_exchange_token");
    exchangeUrl.searchParams.set("client_id", appId);
    exchangeUrl.searchParams.set("client_secret", appSecret);
    exchangeUrl.searchParams.set("fb_exchange_token", code);

    try {
      const exRes = await fetch(exchangeUrl.toString(), { method: "GET" });
      const exText = await exRes.text();
      if (exRes.ok) {
        const parsed = JSON.parse(exText) as Record<string, unknown>;
        if (parsed.access_token) {
          logger.info("[whatsapp-onboarding] exchanged short-lived token for long-lived token");
          return {
            accessToken: String(parsed.access_token).trim(),
            tokenType: String(parsed.token_type ?? "bearer").trim(),
            expiresInSec: typeof parsed.expires_in === "number" ? parsed.expires_in : Number(parsed.expires_in) || null,
          };
        }
      }
    } catch (_) {}
    return {
      accessToken: code,
      tokenType: "bearer",
      expiresInSec: 5184000,
    };
  }

  // Embedded Signup (override_default_response_type): exchange WITHOUT redirect_uri.
  const url = new URL(`https://graph.facebook.com/${graphApiVersion}/oauth/access_token`);
  url.searchParams.set("client_id", appId);
  url.searchParams.set("client_secret", appSecret);
  url.searchParams.set("code", code);

  let res = await fetch(url.toString(), { method: "GET" });
  const text = await res.text();

  let data: Record<string, unknown> = {};
  try {
    data = JSON.parse(text) as Record<string, unknown>;
  } catch {
    data = { raw: text };
  }

  if (!res.ok) {
    let err = (data.error ?? {}) as { message?: string; error_subcode?: number; code?: number };
    let subcode = err.error_subcode;
    let message = err.message ?? text;

    // If 36008 occurs and redirectUri is provided, try code exchange with redirectUri variants
    if (subcode === 36008 && opts.redirectUri) {
      const redirectVariants = [
        opts.redirectUri,
        opts.redirectUri.endsWith("/") ? opts.redirectUri.slice(0, -1) : `${opts.redirectUri}/`,
      ];
      for (const variant of redirectVariants) {
        const retryUrl = new URL(`https://graph.facebook.com/${graphApiVersion}/oauth/access_token`);
        retryUrl.searchParams.set("client_id", appId);
        retryUrl.searchParams.set("client_secret", appSecret);
        retryUrl.searchParams.set("code", code);
        retryUrl.searchParams.set("redirect_uri", variant);

        try {
          const retryRes = await fetch(retryUrl.toString(), { method: "GET" });
          const retryText = await retryRes.text();
          if (retryRes.ok) {
            const parsed = JSON.parse(retryText) as Record<string, unknown>;
            if (parsed.access_token) {
              data = parsed;
              res = retryRes;
              logger.info("[whatsapp-onboarding] code exchange fallback succeeded with redirect_uri", { variant });
              break;
            }
          }
        } catch (_) {}
      }
    }

    if (!res.ok) {
      err = (data.error ?? {}) as { message?: string; error_subcode?: number; code?: number };
      subcode = err.error_subcode;
      message = err.message ?? text;
      logger.warn("[whatsapp-onboarding] code exchange failed", {
        status: res.status,
        code: err.code ?? null,
        subcode: subcode ?? null,
        message,
      });
      // Surface the real Meta error to the client (instead of a generic INTERNAL).
      const hint =
        subcode === 36008
          ? " (subcode 36008 — Meta App ko Live mode + Advanced Access permission setup karein)"
          : subcode
            ? ` (subcode ${subcode})`
            : "";
      throw new HttpsError("failed-precondition", `Meta code exchange failed: ${message}${hint}`);
    }
  }

  const accessToken = String(data.access_token ?? "").trim();
  if (!accessToken) {
    throw new HttpsError("failed-precondition", "Meta OAuth response missing access_token");
  }

  const expiresRaw = data.expires_in;
  const expiresInSec =
    typeof expiresRaw === "number" && Number.isFinite(expiresRaw)
      ? expiresRaw
      : Number.isFinite(Number(expiresRaw))
        ? Number(expiresRaw)
        : null;

  return {
    accessToken,
    tokenType: String(data.token_type ?? "").trim() || null,
    expiresInSec,
  };
}

export async function fetchDisplayPhoneNumber(opts: {
  phoneNumberId: string;
  accessToken: string;
  graphApiVersion?: string;
}): Promise<string> {
  const phoneNumberId = String(opts.phoneNumberId ?? "").trim();
  if (!phoneNumberId) {
    return "";
  }
  const graphApiVersion = String(opts.graphApiVersion ?? DEFAULT_GRAPH_VERSION).trim();
  const url = new URL(`https://graph.facebook.com/${graphApiVersion}/${phoneNumberId}`);
  url.searchParams.set("fields", "display_phone_number");

  const res = await fetch(url.toString(), {
    method: "GET",
    headers: { Authorization: `Bearer ${opts.accessToken}` },
  });
  const text = await res.text();
  if (!res.ok) {
    logger.warn("[whatsapp-onboarding] display phone lookup failed", {
      status: res.status,
      phoneNumberId,
    });
    return "";
  }
  try {
    const data = JSON.parse(text) as { display_phone_number?: string };
    return String(data.display_phone_number ?? "").trim();
  } catch {
    return "";
  }
}

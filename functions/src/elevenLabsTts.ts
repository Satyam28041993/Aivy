import { logger } from "firebase-functions";
import { defineSecret } from "firebase-functions/params";
import { HttpsError, onCall } from "firebase-functions/v2/https";

// Binds at deploy; read via process.env.ELEVENLABS_API_KEY in the handler.
const elevenLabsApiKey = defineSecret("ELEVENLABS_API_KEY");

/** Strip whitespace and accidental wrapping quotes from pasted secrets. */
function normalizeApiKey(raw: string): string {
  let k = raw.trim();
  if (k.length >= 2) {
    const q0 = k[0];
    const q1 = k[k.length - 1];
    if ((q0 === '"' && q1 === '"') || (q0 === "'" && q1 === "'")) {
      k = k.slice(1, -1).trim();
    }
  }
  return k;
}

/** Default Aivy voice (overridable with env ELEVENLABS_VOICE_ID on the function). */
const DEFAULT_VOICE_ID = "XcWoPxj7pwnIgM3dQnWv";

const DEFAULT_GREETING_HI =
  "नमस्ते, मैं ऐवी हूँ। आज मैं आपके बिज़नेस में मदद के लिए तैयार हूँ।";

/**
 * Text → MP3 via ElevenLabs. Returns base64 audio (keeps API key off clients).
 *
 * Setup:
 *   firebase functions:secrets:set ELEVENLABS_API_KEY
 * Optional: set plain env ELEVENLABS_VOICE_ID on the function to override voice.
 */
export const elevenLabsTts = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 120,
    memory: "512MiB",
    secrets: [elevenLabsApiKey],
  },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Authentication required");
    }

    const key = normalizeApiKey(String(process.env.ELEVENLABS_API_KEY ?? ""));
    if (!key) {
      logger.error("ELEVENLABS_API_KEY missing after secret bind");
      throw new HttpsError(
        "failed-precondition",
        "ElevenLabs is not configured. Set secret ELEVENLABS_API_KEY for functions.",
      );
    }

    const body =
      typeof request.data === "object" && request.data !== null
        ? (request.data as { text?: unknown })
        : {};
    const raw = typeof body.text === "string" ? body.text.trim() : "";
    const text = raw.length > 0 ? raw : DEFAULT_GREETING_HI;

    if (text.length > 2500) {
      throw new HttpsError("invalid-argument", "Text too long (max 2500 chars)");
    }

    const voiceId =
      String(process.env.ELEVENLABS_VOICE_ID ?? "").trim() || DEFAULT_VOICE_ID;

    const url = `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(
      voiceId,
    )}`;

    const res = await fetch(url, {
      method: "POST",
      headers: {
        "xi-api-key": key,
        "Content-Type": "application/json",
        Accept: "audio/mpeg",
      },
      body: JSON.stringify({
        model_id: "eleven_multilingual_v2",
        text,
      }),
    });

    if (!res.ok) {
      const errText = await res.text();
      logger.error("ElevenLabs HTTP error", {
        status: res.status,
        body: errText.slice(0, 800),
      });
      // 401/403: bad or revoked xi-api-key in Firebase secret (not an app bug).
      if (res.status === 401 || res.status === 403) {
        throw new HttpsError(
          "failed-precondition",
          "ElevenLabs API key rejected. In Firebase run: firebase functions:secrets:set ELEVENLABS_API_KEY — paste a fresh key from https://elevenlabs.io/app/settings/api-keys then redeploy functions.",
        );
      }
      if (res.status === 402 || res.status === 429) {
        throw new HttpsError(
          "resource-exhausted",
          "ElevenLabs quota or rate limit reached. Check your ElevenLabs plan and try again later.",
        );
      }
      throw new HttpsError(
        "internal",
        `ElevenLabs request failed (${res.status}).`,
      );
    }

    const buf = Buffer.from(await res.arrayBuffer());
    return {
      audioBase64: buf.toString("base64"),
      mimeType: "audio/mpeg",
    };
  },
);

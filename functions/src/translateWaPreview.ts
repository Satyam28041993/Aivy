import { logger } from "firebase-functions";
import { defineSecret } from "firebase-functions/params";
import { HttpsError, onCall } from "firebase-functions/v2/https";

const geminiApiKey = defineSecret("GEMINI_API_KEY");
const geminiEndpoint =
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent";

function googleGenerativeApiHeaders(key: string): Record<string, string> {
  return {
    "Content-Type": "application/json",
    "x-goog-api-key": key,
  };
}

type GeminiGenerateContentResponse = {
  candidates?: Array<{
    content?: { parts?: Array<{ text?: string }> };
  }>;
};

function textFromGenerateContent(data: GeminiGenerateContentResponse): string {
  const parts = data.candidates?.[0]?.content?.parts;
  if (!parts?.length) {
    return "";
  }
  return parts
    .map((p) => (typeof p.text === "string" ? p.text : ""))
    .join("")
    .trim();
}

/**
 * One-line professional English for WhatsApp preview (chat confirm step).
 */
export const translateWaPreview = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 30,
    secrets: [geminiApiKey],
  },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Authentication required");
    }
    const body =
      typeof request.data === "object" && request.data !== null
        ? (request.data as { text?: unknown })
        : {};
    const text = typeof body.text === "string" ? body.text.trim() : "";
    if (!text) {
      throw new HttpsError("invalid-argument", "text required");
    }
    const key = process.env.GEMINI_API_KEY || "";
    if (!key) {
      throw new HttpsError("failed-precondition", "Gemini not configured");
    }
    const prompt =
      "Translate the following Indian Hindi/Hinglish business WhatsApp line into ONE concise professional English sentence.\n" +
      "Rules: output ONLY the English sentence; no quotes; no explanation; no prefix.\n\n" +
      text;

    const payload = JSON.stringify({
      contents: [{ role: "user", parts: [{ text: prompt }] }],
      generationConfig: {
        temperature: 0.2,
        maxOutputTokens: 256,
      },
    });

    const res = await fetch(geminiEndpoint, {
      method: "POST",
      headers: googleGenerativeApiHeaders(key),
      body: payload,
    });
    const raw = await res.text();
    let data: GeminiGenerateContentResponse;
    try {
      data = JSON.parse(raw) as GeminiGenerateContentResponse;
    } catch {
      logger.error("[translateWaPreview] bad JSON", { raw: raw.slice(0, 200) });
      throw new HttpsError("internal", "Translation failed");
    }
    if (!res.ok) {
      const msg =
        (data as unknown as { error?: { message?: string } })?.error
          ?.message || raw.slice(0, 200);
      logger.error("[translateWaPreview] Gemini HTTP error", {
        status: res.status,
        msg,
      });
      throw new HttpsError("internal", msg || "Translation failed");
    }
    const english = textFromGenerateContent(data);
    if (!english) {
      throw new HttpsError("internal", "Empty translation");
    }
    return { english };
  },
);

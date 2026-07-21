import { logger } from "firebase-functions";

const DEVANAGARI = /[\u0900-\u097F]/;

const GEMINI_ENDPOINT =
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent";

/** Short rule block for LLM prompts (chat + voice). */
export const ROMAN_HINGLISH_WRITING_RULE = `Write ALL user-facing Hindi in Roman script only (English/Latin letters), e.g. "Theek hai, reminder set ho gaya" — NEVER use Devanagari (Hindi script) characters like ठीक or मैं.`;

export function containsDevanagari(text: string): boolean {
  return DEVANAGARI.test(text);
}

function textFromGeminiPayload(data: unknown): string {
  if (!data || typeof data !== "object") {
    return "";
  }
  const candidates = (data as { candidates?: unknown[] }).candidates;
  const first = candidates?.[0];
  if (!first || typeof first !== "object") {
    return "";
  }
  const parts = (first as { content?: { parts?: unknown[] } }).content?.parts;
  if (!Array.isArray(parts)) {
    return "";
  }
  return parts
    .map((p) =>
      p && typeof p === "object" && typeof (p as { text?: string }).text === "string"
        ? (p as { text: string }).text
        : "",
    )
    .join("")
    .trim();
}

/**
 * If the model still returned Devanagari, rewrite to Roman Hinglish via Gemini.
 */
export async function romanizeUserFacingText(
  text: string,
  geminiKey: string,
): Promise<string> {
  const trimmed = text.trim();
  if (!trimmed || !containsDevanagari(trimmed)) {
    return text;
  }

  const body = JSON.stringify({
    contents: [
      {
        role: "user",
        parts: [
          {
            text: `Rewrite for a mobile chat app in natural Roman Hinglish (Hindi spelled with English letters only).
Keep names, numbers, ₹ amounts, and English words unchanged. No Devanagari. No quotes or labels — output only the rewritten text.

TEXT:
${trimmed}`,
          },
        ],
      },
    ],
    generationConfig: { temperature: 0.1, maxOutputTokens: 512 },
  });

  try {
    const res = await fetch(GEMINI_ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-goog-api-key": geminiKey,
      },
      body,
    });
    if (!res.ok) {
      logger.warn("romanizeUserFacingText: Gemini HTTP", { status: res.status });
      return text;
    }
    const data = (await res.json()) as unknown;
    const out = textFromGeminiPayload(data).replace(/```[\s\S]*?```/g, "").trim();
    if (!out || containsDevanagari(out)) {
      return text;
    }
    return out;
  } catch (e) {
    logger.warn("romanizeUserFacingText failed", {
      err: e instanceof Error ? e.message : String(e),
    });
    return text;
  }
}

export type RomanHinglishFields = {
  userReply?: string;
  assistantReply?: string;
  message?: string;
  summary?: string;
  keyPoints?: string[];
  actionItems?: string[];
  followUpSuggestions?: Array<{ when?: string; reason?: string }>;
};

export async function applyRomanHinglishFields<T extends RomanHinglishFields>(
  response: T,
  geminiKey: string,
): Promise<T> {
  const out = { ...response };

  const scalarFields = [
    "userReply",
    "assistantReply",
    "message",
    "summary",
  ] as const;
  for (const field of scalarFields) {
    const v = out[field];
    if (typeof v === "string" && containsDevanagari(v)) {
      out[field] = await romanizeUserFacingText(v, geminiKey);
    }
  }

  if (Array.isArray(out.keyPoints)) {
    out.keyPoints = await Promise.all(
      out.keyPoints.map(async (line) =>
        typeof line === "string" && containsDevanagari(line)
          ? await romanizeUserFacingText(line, geminiKey)
          : line,
      ),
    );
  }

  if (Array.isArray(out.actionItems)) {
    out.actionItems = await Promise.all(
      out.actionItems.map(async (line) =>
        typeof line === "string" && containsDevanagari(line)
          ? await romanizeUserFacingText(line, geminiKey)
          : line,
      ),
    );
  }

  if (Array.isArray(out.followUpSuggestions)) {
    out.followUpSuggestions = await Promise.all(
      out.followUpSuggestions.map(async (item) => {
        if (!item || typeof item !== "object") {
          return item;
        }
        const next = { ...item };
        if (typeof next.when === "string" && containsDevanagari(next.when)) {
          next.when = await romanizeUserFacingText(next.when, geminiKey);
        }
        if (typeof next.reason === "string" && containsDevanagari(next.reason)) {
          next.reason = await romanizeUserFacingText(next.reason, geminiKey);
        }
        return next;
      }),
    );
  }

  return out;
}

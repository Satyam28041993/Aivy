/**
 * What every Gemini call cost — so the user can see, in Settings, what went in,
 * what came out, and roughly what it would bill at the live API price.
 *
 * One row per turn in `users/{uid}/aiUsage/{autoId}`, written best-effort
 * after the reply is ready: a failed log line must never cost the reply.
 *
 * The token counts are Gemini's own (`usageMetadata` on every response). The
 * cost is our arithmetic at Google's published standard paid-tier price for
 * the model, so it is what the turn *would* bill on a paid key — on the free
 * tier the real charge is nothing. Prices change; they are here, in one place.
 */

import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";

/** Gemini's per-response token counts. Every field may be missing. */
export interface GeminiUsageMetadata {
  promptTokenCount?: number;
  candidatesTokenCount?: number;
  thoughtsTokenCount?: number;
  cachedContentTokenCount?: number;
  toolUsePromptTokenCount?: number;
  totalTokenCount?: number;
}

export interface TurnUsage {
  /** Prompt tokens across every hop, cached ones included. */
  inputTokens: number;
  /** Tokens of the visible answer and tool calls. */
  outputTokens: number;
  /** Thinking tokens — billed as output. */
  thinkingTokens: number;
  /** Of `inputTokens`, how many were served from Gemini's cache. */
  cachedTokens: number;
  /** Model calls this turn — one per hop. */
  calls: number;
}

export const EMPTY_USAGE: TurnUsage = {
  inputTokens: 0,
  outputTokens: 0,
  thinkingTokens: 0,
  cachedTokens: 0,
  calls: 0,
};

/**
 * USD per 1M tokens, Gemini Developer API standard paid tier
 * (ai.google.dev/gemini-api/docs/pricing). Text/image/PDF input; output
 * includes thinking. Cached input is a tenth of the input price.
 */
export const PRICES: Record<string, { input: number; output: number; cachedInput: number }> = {
  "gemini-2.5-flash": { input: 0.3, output: 2.5, cachedInput: 0.03 },
  // The same model hearing audio: audio input is billed at $1.00.
  "gemini-2.5-flash-audio": { input: 1.0, output: 2.5, cachedInput: 0.1 },
  // Gemini TTS, the fallback voice: text in, audio tokens out at $10.
  "gemini-2.5-flash-preview-tts": { input: 0.5, output: 10, cachedInput: 0.05 },
  // Cloud TTS is per character, passed as extraUsd; no tokens.
  "cloud-tts-neural2": { input: 0, output: 0, cachedInput: 0 },
};

/** Rupees per dollar for the ₹ figure. Rough on purpose — it is an estimate. */
export const USD_TO_INR = 88;

export function addUsage(total: TurnUsage, meta: GeminiUsageMetadata | undefined): TurnUsage {
  const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
  return {
    inputTokens: total.inputTokens + n(meta?.promptTokenCount) + n(meta?.toolUsePromptTokenCount),
    outputTokens: total.outputTokens + n(meta?.candidatesTokenCount),
    thinkingTokens: total.thinkingTokens + n(meta?.thoughtsTokenCount),
    cachedTokens: total.cachedTokens + n(meta?.cachedContentTokenCount),
    calls: total.calls + 1,
  };
}

/** Estimated cost in USD at the model's paid-tier price. */
export function costUsd(model: string, u: TurnUsage): number {
  const p = PRICES[model] ?? PRICES["gemini-2.5-flash"]!;
  const cached = Math.min(u.cachedTokens, u.inputTokens);
  const fresh = u.inputTokens - cached;
  const usd =
    (fresh * p.input + cached * p.cachedInput + (u.outputTokens + u.thinkingTokens) * p.output) / 1_000_000;
  return Math.round(usd * 1_000_000) / 1_000_000;
}

const MAX_INPUT_CHARS = 2000;
const MAX_OUTPUT_CHARS = 4000;

function clip(s: string, max: number): string {
  const t = s.trim();
  return t.length > max ? `${t.slice(0, max)}…` : t;
}

/** Writes one usage row. Never throws. */
export async function logAiUsage(
  uid: string,
  row: {
    source: "chat" | "brief" | "voice";
    model: string;
    input: string;
    output: string;
    tools?: string[];
    usage: TurnUsage;
    chatId?: string | null;
    /** Cost not counted in tokens — Cloud TTS bills per character. */
    extraUsd?: number;
  },
): Promise<void> {
  try {
    const usd = Math.round((costUsd(row.model, row.usage) + (row.extraUsd ?? 0)) * 1_000_000) / 1_000_000;
    const data: Record<string, unknown> = {
      atMs: Date.now(),
      source: row.source,
      model: row.model,
      input: clip(row.input, MAX_INPUT_CHARS),
      output: clip(row.output, MAX_OUTPUT_CHARS),
      tools: row.tools ?? [],
      inputTokens: row.usage.inputTokens,
      outputTokens: row.usage.outputTokens,
      thinkingTokens: row.usage.thinkingTokens,
      cachedTokens: row.usage.cachedTokens,
      calls: row.usage.calls,
      costUsd: usd,
      costInr: Math.round(usd * USD_TO_INR * 10000) / 10000,
    };
    if (row.chatId) data.chatId = row.chatId;
    await getFirestore().collection("users").doc(uid).collection("aiUsage").add(data);
  } catch (e) {
    logger.warn("logAiUsage failed", { err: e instanceof Error ? e.message : String(e) });
  }
}

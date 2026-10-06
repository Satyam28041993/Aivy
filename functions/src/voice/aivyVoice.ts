/**
 * Aivy's voice: hearing the user, and answering out loud.
 *
 * Deliberately not a second assistant. The old voice home had its own command
 * system and was retired for being a fork in the road (e6e5c80). Here voice is
 * only a way in and a way out of the same `aivyAgent` turn:
 *
 *   mic → `aivyTranscribe` (audio → the words, in Roman Hinglish)
 *       → the app sends those words as an ordinary turn
 *       → `aivySpeak` (the reply → an MP3 the app plays).
 *
 * Transcription goes through Gemini rather than the phone's recogniser because
 * this user's speech is Hinglish full of company names and model numbers, and
 * a Hindi-locale recogniser writes "Bajaj Auto" as "बजाज ऑटो" — which would land
 * in the DSR sheet the company reads. Gemini is told to write it the way he
 * types it.
 *
 * Speech uses Google Cloud Text-to-Speech (Neural2, Indian English), which ran
 * here before under the functions' own service account. If that call fails —
 * API off, role missing — Gemini's TTS answers instead, so the feature degrades
 * to a different voice rather than to silence.
 */

import { GoogleAuth } from "google-auth-library";
import { defineSecret } from "firebase-functions/params";
import { logger } from "firebase-functions";
import { HttpsError, onCall } from "firebase-functions/v2/https";

import { addUsage, EMPTY_USAGE, logAiUsage, type GeminiUsageMetadata } from "../agent/aiUsage";

const geminiApiKey = defineSecret("GEMINI_API_KEY");
const REGION = "us-central1";

/** Callables cap a request near 10 MB; a minute of 16 kHz mono WAV is ~2 MB. */
const MAX_AUDIO_BYTES = 6 * 1024 * 1024;
/** Spoken replies are cut here — past this, reading the screen is faster. */
export const MAX_SPOKEN_CHARS = 1200;

const TRANSCRIBE_MODEL = "gemini-2.5-flash";
const TTS_FALLBACK_MODEL = "gemini-2.5-flash-preview-tts";

const TRANSCRIBE_INSTRUCTION = `Transcribe exactly what the speaker says in this audio. Output only the transcript — no quotes, no notes.

The speaker is an Indian salesperson talking to his assistant in Hinglish (Hindi and English mixed). Write everything in Roman script, the way he would type it on WhatsApp — "kal 11 baje Sharma ji ko call karna", never Devanagari. Keep company names, people's names, product and model codes (BX410T, DS2208, TTR), numbers and amounts exactly as said, in English letters and digits. Do not translate, summarise or correct what he means.

If the audio has no speech, output nothing.`;

function keyOf(): string {
  return geminiApiKey.value() || process.env.GEMINI_API_KEY || "";
}

function requireUid(auth: { uid: string } | undefined): string {
  if (!auth?.uid) throw new HttpsError("unauthenticated", "Sign in first.");
  return auth.uid;
}

// ---------------------------------------------------------------------------
// Hearing
// ---------------------------------------------------------------------------

/** The transcript, tidied: one line, no wrapping quotes. */
export function cleanTranscript(raw: string): string {
  return raw
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^["'“”]+|["'“”]+$/g, "")
    .trim();
}

export const aivyTranscribe = onCall(
  { region: REGION, timeoutSeconds: 60, memory: "512MiB", secrets: [geminiApiKey] },
  async (request) => {
    const uid = requireUid(request.auth);
    const payload = (request.data ?? {}) as Record<string, unknown>;
    const audio = typeof payload.audioBase64 === "string" ? payload.audioBase64 : "";
    const mimeType = typeof payload.mimeType === "string" && payload.mimeType ? payload.mimeType : "audio/wav";
    if (!audio) throw new HttpsError("invalid-argument", "audioBase64 is required");
    if ((audio.length * 3) / 4 > MAX_AUDIO_BYTES) {
      throw new HttpsError("invalid-argument", "That recording is too long — keep it under a minute.");
    }

    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${TRANSCRIBE_MODEL}:generateContent`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-goog-api-key": keyOf() },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: TRANSCRIBE_INSTRUCTION }] },
          contents: [{ role: "user", parts: [{ inlineData: { mimeType, data: audio } }] }],
          // Transcription needs no reasoning; thinking only adds delay.
          generationConfig: { temperature: 0, maxOutputTokens: 1024, thinkingConfig: { thinkingBudget: 0 } },
        }),
      },
    );
    if (!res.ok) {
      logger.error("aivyTranscribe: Gemini refused", { status: res.status, body: (await res.text()).slice(0, 300) });
      throw new HttpsError("unavailable", "Could not hear that — try again.");
    }
    const body = (await res.json()) as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
      usageMetadata?: GeminiUsageMetadata;
    };
    const text = cleanTranscript(body.candidates?.[0]?.content?.parts?.map((p) => p.text ?? "").join("") ?? "");
    await logAiUsage(uid, {
      source: "voice",
      model: "gemini-2.5-flash-audio",
      input: "🎤 voice message",
      output: text,
      usage: addUsage(EMPTY_USAGE, body.usageMetadata),
    });
    return { text };
  },
);

// ---------------------------------------------------------------------------
// Speaking
// ---------------------------------------------------------------------------

/**
 * What the reply sounds like read aloud: no markdown stars, no links read out
 * character by character, no emoji names, rupees said as rupees.
 */
export function speakableText(raw: string): string {
  let t = raw
    .replace(/\*\*(.+?)\*\*/g, "$1")
    .replace(/https?:\/\/\S+/g, " (link on screen) ")
    .replace(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]/gu, "")
    .replace(/₹\s?([\d,]+(?:\.\d+)?)/g, "$1 rupees")
    .replace(/^\s*[-*•]\s+/gm, "")
    .replace(/\s*\n+\s*/g, ". ")
    .replace(/(\.\s*){2,}/g, ". ")
    .replace(/\s{2,}/g, " ")
    .trim();
  if (t.length > MAX_SPOKEN_CHARS) {
    const cut = t.slice(0, MAX_SPOKEN_CHARS);
    const end = Math.max(cut.lastIndexOf(". "), cut.lastIndexOf("? "));
    t = `${end > 200 ? cut.slice(0, end + 1) : cut} The rest is on screen.`;
  }
  return t;
}

/** Devanagari in the text means a Hindi voice; otherwise Indian English. */
export function voiceFor(text: string): { languageCode: string; name: string } {
  return /[ऀ-ॿ]/.test(text)
    ? { languageCode: "hi-IN", name: "hi-IN-Neural2-A" }
    : { languageCode: "en-IN", name: "en-IN-Neural2-A" };
}

/** Cloud TTS Neural2: $16 per million characters (the first million a month are free). */
const NEURAL2_USD_PER_CHAR = 16 / 1_000_000;

const auth = new GoogleAuth({ scopes: ["https://www.googleapis.com/auth/cloud-platform"] });

async function cloudTts(text: string): Promise<{ audioBase64: string; mimeType: string }> {
  const token = await auth.getAccessToken();
  const res = await fetch("https://texttospeech.googleapis.com/v1/text:synthesize", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify({
      input: { text },
      voice: voiceFor(text),
      audioConfig: { audioEncoding: "MP3", speakingRate: 1.05 },
    }),
  });
  if (!res.ok) {
    throw new Error(`Cloud TTS ${res.status}: ${(await res.text()).slice(0, 200)}`);
  }
  const body = (await res.json()) as { audioContent?: string };
  if (!body.audioContent) throw new Error("Cloud TTS returned no audio");
  return { audioBase64: body.audioContent, mimeType: "audio/mpeg" };
}

/** Raw 16-bit PCM → a WAV file any player opens. */
export function pcmToWav(pcm: Buffer, sampleRate: number, channels = 1): Buffer {
  const header = Buffer.alloc(44);
  const byteRate = sampleRate * channels * 2;
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(channels * 2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

async function geminiTts(
  text: string,
): Promise<{ audioBase64: string; mimeType: string; usage?: GeminiUsageMetadata }> {
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${TTS_FALLBACK_MODEL}:generateContent`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": keyOf() },
      body: JSON.stringify({
        contents: [{ parts: [{ text: `Say warmly, in a natural Indian English voice: ${text}` }] }],
        generationConfig: {
          responseModalities: ["AUDIO"],
          speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: "Kore" } } },
        },
      }),
    },
  );
  if (!res.ok) throw new Error(`Gemini TTS ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const body = (await res.json()) as {
    candidates?: Array<{ content?: { parts?: Array<{ inlineData?: { mimeType?: string; data?: string } }> } }>;
    usageMetadata?: GeminiUsageMetadata;
  };
  const part = body.candidates?.[0]?.content?.parts?.find((p) => p.inlineData?.data)?.inlineData;
  if (!part?.data) throw new Error("Gemini TTS returned no audio");
  const rate = Number(/rate=(\d+)/.exec(part.mimeType ?? "")?.[1] ?? 24000);
  const wav = pcmToWav(Buffer.from(part.data, "base64"), rate);
  return { audioBase64: wav.toString("base64"), mimeType: "audio/wav", usage: body.usageMetadata };
}

export const aivySpeak = onCall(
  { region: REGION, timeoutSeconds: 60, memory: "512MiB", secrets: [geminiApiKey] },
  async (request) => {
    const uid = requireUid(request.auth);
    const payload = (request.data ?? {}) as Record<string, unknown>;
    const text = speakableText(typeof payload.text === "string" ? payload.text : "");
    if (!text) throw new HttpsError("invalid-argument", "Nothing to say.");

    try {
      const out = await cloudTts(text);
      await logAiUsage(uid, {
        source: "voice",
        model: "cloud-tts-neural2",
        input: "🔊 spoken reply",
        output: text,
        usage: { ...EMPTY_USAGE, calls: 1 },
        extraUsd: text.length * NEURAL2_USD_PER_CHAR,
      });
      return out;
    } catch (e) {
      logger.warn("aivySpeak: Cloud TTS failed, using Gemini TTS", { err: e instanceof Error ? e.message : String(e) });
    }
    try {
      const out = await geminiTts(text);
      await logAiUsage(uid, {
        source: "voice",
        model: TTS_FALLBACK_MODEL,
        input: "🔊 spoken reply",
        output: text,
        usage: addUsage(EMPTY_USAGE, out.usage),
      });
      return { audioBase64: out.audioBase64, mimeType: out.mimeType };
    } catch (e) {
      logger.error("aivySpeak: no voice available", { err: e instanceof Error ? e.message : String(e) });
      throw new HttpsError("unavailable", "Voice is not available right now — the reply is on screen.");
    }
  },
);

/**
 * Google Cloud Speech-to-Text + Text-to-Speech helpers for Aivy.
 *
 * Credentials: prefer default Application Credentials on Cloud Functions
 * (grant the Functions runtime service account `roles/speech.client` and
 * `roles/texttospeech.user` on project aivy-5c031). Optional override: set
 * secret/env GOOGLE_VOICE_SA_JSON to the raw JSON of a dedicated service account.
 */

import { randomUUID } from "node:crypto";

import { TextToSpeechClient } from "@google-cloud/text-to-speech";
import { SpeechClient, protos } from "@google-cloud/speech";
import { getStorage } from "firebase-admin/storage";
import { logger } from "firebase-functions";
import { HttpsError, onCall } from "firebase-functions/v2/https";

const DEFAULT_BUCKET = "aivy-5c031.firebasestorage.app";

function storageBucketName(): string {
  return (
    process.env.FIREBASE_STORAGE_BUCKET?.trim() ||
    process.env.GCLOUD_STORAGE_BUCKET?.trim() ||
    DEFAULT_BUCKET
  );
}

function speechClient(): SpeechClient {
  const raw = process.env.GOOGLE_VOICE_SA_JSON?.trim();
  if (raw) {
    try {
      const creds = JSON.parse(raw) as { project_id?: string };
      return new SpeechClient({
        credentials: creds as Record<string, unknown>,
        projectId: creds.project_id,
      });
    } catch (e) {
      logger.error("Invalid GOOGLE_VOICE_SA_JSON", {
        err: e instanceof Error ? e.message : String(e),
      });
      throw new HttpsError("failed-precondition", "Invalid GOOGLE_VOICE_SA_JSON");
    }
  }
  return new SpeechClient();
}

function ttsClient(): TextToSpeechClient {
  const raw = process.env.GOOGLE_VOICE_SA_JSON?.trim();
  if (raw) {
    const creds = JSON.parse(raw) as { project_id?: string };
    return new TextToSpeechClient({
      credentials: creds as Record<string, unknown>,
      projectId: creds.project_id,
    });
  }
  return new TextToSpeechClient();
}

function decodeStoragePathFromDownloadUrl(audioUrl: string): string {
  const pathRaw = audioUrl.split("/o/")[1]?.split("?")[0];
  if (!pathRaw) {
    throw new Error(`Invalid storage URL format: ${audioUrl}`);
  }
  return decodeURIComponent(pathRaw);
}

async function downloadStorageBytes(audioUrl: string): Promise<Buffer> {
  const filePath = decodeStoragePathFromDownloadUrl(audioUrl);
  const bucket = getStorage().bucket(storageBucketName());
  const [buf] = await bucket.file(filePath).download();
  if (!buf.length) {
    throw new Error("Empty audio download");
  }
  return buf;
}

function pickEncodingForPath(filePath: string): {
  encoding: protos.google.cloud.speech.v1.RecognitionConfig.AudioEncoding;
  sampleRateHertz?: number;
} {
  const enc = protos.google.cloud.speech.v1.RecognitionConfig.AudioEncoding;
  const lower = filePath.toLowerCase();
  if (lower.endsWith(".flac")) {
    return { encoding: enc.FLAC, sampleRateHertz: 16000 };
  }
  if (lower.endsWith(".opus") || lower.endsWith(".ogg")) {
    return { encoding: enc.OGG_OPUS, sampleRateHertz: 48000 };
  }
  if (lower.endsWith(".wav")) {
    return { encoding: enc.LINEAR16, sampleRateHertz: 16000 };
  }
  // M4A/AAC from Flutter `record`: let API infer container/codec (v1 has no MP4_AAC enum).
  return { encoding: enc.ENCODING_UNSPECIFIED, sampleRateHertz: 44100 };
}

/**
 * Transcribes audio stored in Firebase Storage (download URL).
 * Optimised for Hindi + English (India) code-switching.
 */
export async function transcribeFromFirebaseStorageUrl(
  audioUrl: string,
): Promise<string> {
  const buf = await downloadStorageBytes(audioUrl);
  const filePath = decodeStoragePathFromDownloadUrl(audioUrl);
  const { encoding, sampleRateHertz } = pickEncodingForPath(filePath);

  const client = speechClient();
  const recognizeTuple = await client.recognize({
    config: {
      encoding,
      ...(sampleRateHertz ? { sampleRateHertz } : {}),
      languageCode: "hi-IN",
      alternativeLanguageCodes: ["en-IN", "en-US"],
      enableAutomaticPunctuation: true,
      model: "latest_short",
      useEnhanced: false,
    },
    audio: { content: buf },
  });
  const response = recognizeTuple[0];

  const parts =
    (response.results ?? [])
      .map((r: protos.google.cloud.speech.v1.ISpeechRecognitionResult) =>
        r.alternatives?.[0]?.transcript?.trim(),
      )
      .filter((t): t is string => typeof t === "string" && t.length > 0);
  const text = parts.join(" ").trim();
  if (!text) {
    throw new Error("Google Speech-to-Text returned an empty transcript");
  }
  return text;
}

type GeminiGenerateContentResponse = {
  candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
};

function textFromGemini(data: GeminiGenerateContentResponse): string {
  const parts = data.candidates?.[0]?.content?.parts ?? [];
  return parts.map((p) => (typeof p.text === "string" ? p.text : "")).join("");
}

async function fetchGeminiGenerateContent(
  geminiKey: string,
  body: string,
): Promise<GeminiGenerateContentResponse> {
  const response = await fetch(
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-goog-api-key": geminiKey,
      },
      body,
    },
  );
  if (!response.ok) {
    const err = await response.text().catch(() => "");
    throw new Error(`Gemini HTTP ${response.status}: ${err.slice(0, 400)}`);
  }
  return (await response.json()) as GeminiGenerateContentResponse;
}

/** Gemini transcription when Google STT cannot decode the container (e.g. some M4A). */
export async function transcribeWithGeminiFromStorageUrl(
  audioUrl: string,
  opts: { geminiKey: string; timezone: string; nowIso: string },
): Promise<string> {
  const buf = await downloadStorageBytes(audioUrl);
  const filePath = decodeStoragePathFromDownloadUrl(audioUrl).toLowerCase();
  const mimeType = filePath.endsWith(".wav")
    ? "audio/wav"
    : filePath.endsWith(".flac")
      ? "audio/flac"
      : "audio/mp4";

  const prompt = `Transcribe this user audio to plain text.
Rules:
- Keep original meaning and language (Hindi/Hinglish/English). Preserve person names.
- Prefer Roman (Latin) script for Hindi words when reasonable, e.g. "aaj 5 baje" not Devanagari.
- Return only the transcription text, no JSON, no markdown.
Timezone: ${opts.timezone}
Current time: ${opts.nowIso}`;

  const payload = {
    contents: [
      {
        role: "user",
        parts: [
          { text: prompt },
          {
            inlineData: {
              mimeType,
              data: buf.toString("base64"),
            },
          },
        ],
      },
    ],
  };

  const data = await fetchGeminiGenerateContent(
    opts.geminiKey,
    JSON.stringify(payload),
  );
  const text = textFromGemini(data).trim();
  if (!text) {
    throw new Error("Gemini transcription returned empty text");
  }
  return text;
}

/**
 * Google STT first; on failure uses Gemini (same as main chat voice pipeline).
 */
export async function transcribeFromFirebaseStorageUrlWithFallback(
  audioUrl: string,
  opts: { geminiKey: string; timezone: string; nowIso: string },
): Promise<string> {
  try {
    return await transcribeFromFirebaseStorageUrl(audioUrl);
  } catch (googleErr) {
    logger.warn("Google STT failed, falling back to Gemini transcription", {
      err: googleErr instanceof Error ? googleErr.message : String(googleErr),
    });
    if (!opts.geminiKey) {
      throw googleErr;
    }
    return transcribeWithGeminiFromStorageUrl(audioUrl, opts);
  }
}

function buildFirebaseDownloadUrl(bucket: string, objectPath: string, token: string): string {
  const enc = encodeURIComponent(objectPath);
  return `https://firebasestorage.googleapis.com/v0/b/${bucket}/o/${enc}?alt=media&token=${token}`;
}

/**
 * Synthesises speech, stores MP3 under users/{uid}/tts/, returns download URL.
 */
export async function synthesizeToFirebaseStorage(opts: {
  uid: string;
  text: string;
}): Promise<string> {
  const text = opts.text.trim();
  if (!text) {
    throw new HttpsError("invalid-argument", "Text is required");
  }
  if (text.length > 5000) {
    throw new HttpsError("invalid-argument", "Text too long (max 5000 chars)");
  }

  const client = ttsClient();
  const [ttsResponse] = await client.synthesizeSpeech({
    input: { text },
    voice: {
      languageCode: "hi-IN",
      name: "hi-IN-Neural2-D",
      ssmlGender: "FEMALE",
    },
    audioConfig: {
      audioEncoding: "MP3",
      speakingRate: 0.96,
      pitch: -1.2,
    },
  });

  const audio = ttsResponse.audioContent as Buffer | Uint8Array | string | null | undefined;
  if (audio == null) {
    throw new Error("TTS returned no audio");
  }
  const bytes = typeof audio === "string" ? Buffer.from(audio, "base64") : Buffer.from(audio);
  if (!bytes.length) {
    throw new Error("TTS audio buffer empty");
  }

  const bucketName = storageBucketName();
  const bucket = getStorage().bucket(bucketName);
  const token = randomUUID();
  const objectPath = `users/${opts.uid}/tts/${token}.mp3`;
  const file = bucket.file(objectPath);
  await file.save(bytes, {
    resumable: false,
    metadata: {
      contentType: "audio/mpeg",
      cacheControl: "public,max-age=31536000",
      metadata: {
        firebaseStorageDownloadTokens: token,
      },
    },
  });

  return buildFirebaseDownloadUrl(bucketName, objectPath, token);
}

/** Callable: authenticated text → stored MP3 URL (keeps keys off the client). */
export const googleSpeechSynthesize = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 120,
    memory: "512MiB",
  },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Authentication required");
    }
    const body =
      typeof request.data === "object" && request.data !== null
        ? (request.data as { text?: unknown })
        : {};
    const raw = typeof body.text === "string" ? body.text.trim() : "";
    if (!raw) {
      throw new HttpsError("invalid-argument", "text is required");
    }
    const url = await synthesizeToFirebaseStorage({
      uid: request.auth.uid,
      text: raw,
    });
    return { audioUrl: url };
  },
);

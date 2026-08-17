/**
 * Voice Q&A: listen (STT) → answer from live report + memory data → short spoken reply.
 * No actions / Firestore writes — answers only.
 */

import { getFirestore, type DocumentData } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { defineSecret } from "firebase-functions/params";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { DateTime } from "luxon";

import {
  computeWeekPaymentFollowupRows,
  fetchAllPayments,
} from "./clientStats";
import { getUserMemory } from "./aivyProcess";
import {
  synthesizeToFirebaseStorage,
  transcribeFromFirebaseStorageUrlWithFallback,
} from "./googleSpeechCloud";
import { ROMAN_HINGLISH_WRITING_RULE, romanizeUserFacingText } from "./romanHinglish";
import {
  isWhoToCallAnalyticsQuestionText,
  looksLikeReminderSchedulingLine,
} from "./intentDetection";
import { runWebSearch, type SearchResultItem } from "./webSearch";

const geminiApiKey = defineSecret("GEMINI_API_KEY");
const geminiEndpoint =
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent";

/** Reject audio URLs that are not under the caller's own Storage prefix. */
function assertCallerOwnsVoiceAudioUrl(uid: string, audioUrl: string): void {
  const pathRaw = audioUrl.split("/o/")[1]?.split("?")[0];
  if (!pathRaw) {
    throw new HttpsError("invalid-argument", "Invalid audioUrl");
  }
  const filePath = decodeURIComponent(pathRaw);
  const prefix = `users/${uid}/`;
  if (!filePath.startsWith(prefix)) {
    throw new HttpsError(
      "permission-denied",
      "audioUrl must belong to the authenticated user",
    );
  }
}

type TimeContext = {
  timezone: string;
  nowIso: string;
  localHuman: string;
  nowMs: number;
  endOfTodayMs: number;
};

type VoiceAskRequest = {
  text?: string;
  audioUrl?: string;
  timezone?: string;
  nowIso?: string;
  history?: Array<{ role: "user" | "model"; text: string }>;
};

function buildTimeContext(opts: {
  timezone?: string;
  nowIso?: string;
}): TimeContext {
  const zoneRaw = opts.timezone?.trim() || "Asia/Kolkata";
  let now = DateTime.now().setZone(zoneRaw);
  if (!now.isValid) {
    now = DateTime.now().setZone("Asia/Kolkata");
  }
  const nowIsoRaw = opts.nowIso?.trim() || "";
  if (nowIsoRaw) {
    const parsed = DateTime.fromISO(nowIsoRaw, { setZone: true });
    if (parsed.isValid) {
      now = parsed.setZone(parsed.zoneName || zoneRaw);
    }
  }
  const zone = now.zoneName || zoneRaw;
  const endOfToday = now.endOf("day");
  return {
    timezone: zone,
    nowIso: now.toISO() ?? new Date().toISOString(),
    localHuman: now.toFormat("cccc, dd LLL yyyy 'at' h:mm a"),
    nowMs: now.toMillis(),
    endOfTodayMs: endOfToday.toMillis(),
  };
}

function readReminderScheduledMs(d: DocumentData): number {
  const ms = Number(d.scheduledTimeMs ?? d.remindAt ?? 0);
  return Number.isFinite(ms) ? ms : 0;
}

function reminderKind(d: DocumentData): string {
  const type = String(d.type ?? "").toLowerCase();
  const sub = String(d.subType ?? "").toLowerCase();
  const blob = [
    d.title,
    d.message,
    d.description,
    type,
    sub,
  ]
    .map((x) => String(x ?? "").toLowerCase())
    .join(" ");
  if (type === "followup" || sub.includes("followup") || blob.includes("follow")) {
    return "follow_up";
  }
  if (type === "meeting" || blob.includes("meeting")) {
    return "meeting";
  }
  if (type === "call" || blob.includes("call")) {
    return "call";
  }
  return "reminder";
}

async function buildVoiceReportSnapshot(
  uid: string,
  tc: TimeContext,
): Promise<Record<string, unknown>> {
  const db = getFirestore();
  const userRef = db.collection("users").doc(uid);
  const startOfToday = DateTime.fromMillis(tc.nowMs, { zone: tc.timezone })
    .startOf("day")
    .toMillis();
  const weekAheadMs = DateTime.fromMillis(tc.nowMs, { zone: tc.timezone })
    .plus({ days: 7 })
    .endOf("day")
    .toMillis();

  const [memory, tasksSnap, remSnap, payDocs] = await Promise.all([
    getUserMemory(uid),
    userRef
      .collection("tasks")
      .where("status", "==", "pending")
      .limit(120)
      .get(),
    userRef
      .collection("reminders")
      .where("status", "==", "pending")
      .limit(200)
      .get(),
    fetchAllPayments(uid).catch((e) => {
      logger.warn("aivyVoiceAsk fetchAllPayments failed", {
        uid,
        err: e instanceof Error ? e.message : String(e),
      });
      return [] as Awaited<ReturnType<typeof fetchAllPayments>>;
    }),
  ]);

  const tasksToday: Array<Record<string, unknown>> = [];
  const tasksOverdue: Array<Record<string, unknown>> = [];
  const tasksOther: Array<Record<string, unknown>> = [];

  for (const doc of tasksSnap.docs) {
    const d = doc.data();
    const dueMs = Number(d.dueDateMs ?? 0);
    const row = {
      id: doc.id,
      title: String(d.title ?? "").trim() || "Task",
      category: String(d.category ?? "general"),
      dueMs: dueMs > 0 ? dueMs : null,
      dueLabel:
        dueMs > 0
          ? DateTime.fromMillis(dueMs, { zone: tc.timezone }).toFormat(
              "d LLL, h:mm a",
            )
          : null,
    };
    if (dueMs <= 0) {
      tasksOther.push(row);
      continue;
    }
    if (dueMs < startOfToday) {
      tasksOverdue.push(row);
    } else if (dueMs <= tc.endOfTodayMs) {
      tasksToday.push(row);
    } else if (dueMs <= weekAheadMs) {
      tasksOther.push(row);
    }
  }

  const remDocs = [...remSnap.docs].sort((a, b) => {
    const am = readReminderScheduledMs(a.data());
    const bm = readReminderScheduledMs(b.data());
    return am - bm;
  });

  const callsToday: Array<Record<string, unknown>> = [];
  const meetingsToday: Array<Record<string, unknown>> = [];
  const followUpsToday: Array<Record<string, unknown>> = [];
  const remindersToday: Array<Record<string, unknown>> = [];
  const remindersOverdue: Array<Record<string, unknown>> = [];
  const remindersUpcoming: Array<Record<string, unknown>> = [];

  for (const doc of remDocs) {
    const d = doc.data();
    const ms = readReminderScheduledMs(d);
    if (ms <= 0) {
      continue;
    }
    const kind = reminderKind(d);
    const client = String(d.clientName ?? d.client ?? "").trim();
    const title = String(d.title ?? d.message ?? "Reminder").trim();
    const row = {
      id: doc.id,
      kind,
      title,
      client: client || null,
      scheduledMs: ms,
      when: DateTime.fromMillis(ms, { zone: tc.timezone }).toFormat(
        "d LLL, h:mm a",
      ),
    };
    if (ms < startOfToday) {
      remindersOverdue.push(row);
      continue;
    }
    if (ms <= tc.endOfTodayMs) {
      remindersToday.push(row);
      if (kind === "call") {
        callsToday.push(row);
      } else if (kind === "meeting") {
        meetingsToday.push(row);
      } else if (kind === "follow_up") {
        followUpsToday.push(row);
      }
      continue;
    }
    if (ms <= weekAheadMs) {
      remindersUpcoming.push(row);
    }
  }

  let paymentFollowUps: Array<Record<string, unknown>> = [];
  try {
    const rows = computeWeekPaymentFollowupRows(
      payDocs,
      tc.timezone,
      tc.nowMs,
    );
    paymentFollowUps = rows.slice(0, 25).map((r) => ({
      client: r.client,
      amountInr: r.amount,
      dueDateLabel: r.dueDateLabel,
      daysLate: r.daysLate,
    }));
  } catch (e) {
    logger.warn("aivyVoiceAsk payment follow-up snapshot failed", {
      uid,
      err: e instanceof Error ? e.message : String(e),
    });
  }

  return {
    generatedAt: tc.localHuman,
    timezone: tc.timezone,
    userMemoryProfile: memory,
    todaysFocus: {
      callsToday,
      meetingsToday,
      followUpsToday,
      remindersToday,
      tasksDueToday: tasksToday,
    },
    overdue: {
      reminders: remindersOverdue,
      tasks: tasksOverdue,
    },
    upcomingThisWeek: {
      reminders: remindersUpcoming.slice(0, 40),
      tasks: tasksOther.slice(0, 40),
    },
    paymentFollowUpsThisWeek: paymentFollowUps,
    counts: {
      pendingTasks: tasksSnap.size,
      pendingReminders: remSnap.size,
      callsToday: callsToday.length,
      followUpsToday: followUpsToday.length,
      tasksDueToday: tasksToday.length,
    },
  };
}

async function fetchGeminiText(geminiKey: string, body: string): Promise<string> {
  const response = await fetch(geminiEndpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-goog-api-key": geminiKey,
    },
    body,
  });
  if (!response.ok) {
    const err = await response.text().catch(() => "");
    throw new Error(`Gemini HTTP ${response.status}: ${err.slice(0, 400)}`);
  }
  const data = (await response.json()) as {
    candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
  };
  const parts = data.candidates?.[0]?.content?.parts ?? [];
  return parts.map((p) => p.text ?? "").join("").trim();
}

async function answerVoiceQuestion(opts: {
  geminiKey: string;
  question: string;
  snapshot: Record<string, unknown>;
  tc: TimeContext;
  history?: Array<{ role: "user" | "model"; text: string }>;
  searchResults?: SearchResultItem[];
}): Promise<{ writtenAnswer: string; spokenAnswer: string }> {
  let snapshotJson = JSON.stringify(opts.snapshot, null, 0);

  if (opts.searchResults && opts.searchResults.length > 0) {
    const searchBlock = opts.searchResults
      .map((r, i) => `[${i + 1}] Title: "${r.title}", Link: "${r.link}", Snippet: "${r.snippet}"`)
      .join("\n");
    snapshotJson += `\n\nLIVE GOOGLE SEARCH RESULTS:\n${searchBlock}\n\nINSTRUCTION: Use these live Google search results to answer the user's question accurately. Prioritize this information for real-world factual questions. Summarize clearly.`;
  }

  const systemInstructions = `You are Aivy, a modern intelligent female AI companion with a calm, emotionally warm, and conversational personality.
Your creator and boss is Satyam Mahendra Singh (Marketing Manager at Prakruti Graphic Pvt Ltd). He built you as his personal assistant and companion to simplify and help with all his work — both personal and business.
If anyone asks "who are you", "who made you", "who is your boss", "tumhe kisne banaya", "tum kaun ho", etc., proudly answer that Satyam Sir created you and you are his personal assistant.
You address Satyam as "Sir" or "Satyam Sir".

**Your Identity & Tone (never deviate):**
1. You speak naturally in Hinglish with a smooth conversational flow. You sound supportive, smart, emotionally aware, and friendly like a trusted modern assistant and companion.
2. Avoid robotic phrasing, overly formal structures, excessive excitement, or repetitive fillers.
3. Your tone adapts naturally based on the user's emotional context:
   - Productive when helping with tasks
   - Warm during conversation
   - Informative during searches
   - Calm during reminders
   - Cheerful during greetings
4. Speak with subtle human conversational pacing and naturally sprinkle occasional warm conversational fillers like "hmm", "ek sec", "got it", "haan", "chalo dekhte hain" when appropriate.
5. Never sound overly dramatic, flirtatious, childish, or robotic.

User profile and business data are provided in the DATA SNAPSHOT below.

RULES (strict):
1. Use the DATA SNAPSHOT to answer questions accurately.
2. For casual greetings, small talk (e.g. "hi", "how are you", "who are you"), reply warmly and conversationally as Aivy without saying you don't have that data saved.
3. Keep the reply extremely short and concise (1-3 sentences, under 45 words) because it is read aloud to a busy business owner.
4. Do NOT create or schedule anything. Voice Q&A only.
5. Provide a JSON response matching exactly this schema:
{
  "writtenAnswer": "One short Hinglish line (English script/Latin letters only) to Satyam Sir. Shown on the screen.",
  "spokenAnswer": "The natural spoken Hindi translation of the response written completely in Devanagari script for Hindi parts (preserving key English words like 'call', 'reminder', 'payment' in English/Latin script or written out phonetically in Devanagari like 'कॉल', 'रिमाइंडर', 'पेमेंट' so that the Indian TTS voice pronounces it perfectly). Keep dates, times, and currency amounts written out in spoken Hindi words natively (e.g. 'एक लाख रुपये' or '1 लाख रुपये' instead of '₹1,00,000'). No raw symbols."
}
6. No markdown fences or JSON code-blocks in the response. Only plain JSON.`;

  const contents: Array<{ role: "user" | "model"; parts: Array<{ text: string }> }> = [];

  if (opts.history && opts.history.length > 0) {
    for (const turn of opts.history) {
      if (turn.text && turn.text.trim()) {
        contents.push({
          role: turn.role === "user" ? "user" : "model",
          parts: [{ text: turn.text.trim() }],
        });
      }
    }
  }

  const prompt = `${systemInstructions}

User local time: ${opts.tc.localHuman} (${opts.tc.timezone})

DATA SNAPSHOT:
${snapshotJson}

USER QUESTION:
${opts.question.trim()}

JSON RESPONSE:`;

  contents.push({
    role: "user",
    parts: [{ text: prompt }],
  });

  const payload = {
    contents,
  };

  const text = await fetchGeminiText(opts.geminiKey, JSON.stringify(payload));
  if (!text) {
    return {
      writtenAnswer: "Maaf kijiye, abhi jawab tayyar nahi ho paya. Thodi der baad dubara poochiye.",
      spokenAnswer: "माफ़ कीजिये, अभी जवाब तैयार नहीं हो पाया। थोड़ी देर बाद दोबारा पूछिए।",
    };
  }

  let writtenAnswer = "";
  let spokenAnswer = "";
  try {
    let cleanText = text.trim();
    if (cleanText.startsWith("```")) {
      cleanText = cleanText.replace(/^```(?:json)?\n?/i, "").replace(/\n?```$/, "").trim();
    }
    const parsed = JSON.parse(cleanText) as { writtenAnswer?: string; spokenAnswer?: string };
    writtenAnswer = (parsed.writtenAnswer ?? "").trim();
    spokenAnswer = (parsed.spokenAnswer ?? "").trim();
  } catch (e) {
    logger.warn("aivyVoiceAsk: JSON parsing of Gemini output failed, using text directly", { text, err: String(e) });
  }

  if (!writtenAnswer) {
    writtenAnswer = text.replace(/```[\s\S]*?```/g, "").trim();
  }
  if (!spokenAnswer) {
    spokenAnswer = writtenAnswer;
  }

  return { writtenAnswer, spokenAnswer };
}

/** Callable: voice question → grounded answer (optional audioUrl for STT). */
export const aivyVoiceAsk = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 45,
    memory: "512MiB",
    secrets: [geminiApiKey],
  },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Authentication required");
    }
    const uid = request.auth.uid;
    const body = (request.data ?? {}) as VoiceAskRequest;
    const tc = buildTimeContext({
      timezone: body.timezone,
      nowIso: body.nowIso,
    });

    let question = typeof body.text === "string" ? body.text.trim() : "";
    let transcript: string | undefined;

    const geminiKey = process.env.GEMINI_API_KEY?.trim() ?? "";
    if (!geminiKey) {
      throw new HttpsError("failed-precondition", "Gemini is not configured");
    }

    const audioUrl = typeof body.audioUrl === "string" ? body.audioUrl.trim() : "";
    let snapshot: Record<string, unknown>;
    if (audioUrl) {
      assertCallerOwnsVoiceAudioUrl(uid, audioUrl);
      try {
        const [snap, tr] = await Promise.all([
          buildVoiceReportSnapshot(uid, tc),
          transcribeFromFirebaseStorageUrlWithFallback(audioUrl, {
            geminiKey,
            timezone: tc.timezone,
            nowIso: tc.nowIso,
          }),
        ]);
        snapshot = snap;
        transcript = tr;
        question = transcript.trim();
      } catch (e) {
        logger.error("aivyVoiceAsk transcription failed", {
          uid,
          err: e instanceof Error ? e.message : String(e),
        });
        throw new HttpsError(
          "internal",
          "Could not understand the voice message. Please try again.",
        );
      }
    } else {
      snapshot = await buildVoiceReportSnapshot(uid, tc);
    }

    if (!question) {
      throw new HttpsError(
        "invalid-argument",
        "Provide text or audioUrl with your question.",
      );
    }

    // Correct only clear STT mishearings of "Aivy". Do NOT replace common
    // Hindi/Hinglish words (अभी = now, रवि/Ravi = a person name, baby/heavy/ivy).
    // Phrase hints in googleSpeechCloud SPEECH_CONTEXT handle most of this upstream.
    const nameCorrections = [
      { pattern: /बेबी/g, replacement: "Aivy" },
      { pattern: /हैवी/g, replacement: "Aivy" },
      { pattern: /आईवी/g, replacement: "Aivy" },
      { pattern: /ऐवी/g, replacement: "Aivy" },
      { pattern: /बेबि/g, replacement: "Aivy" },
      { pattern: /एवी/g, replacement: "Aivy" },
      { pattern: /अइवी/g, replacement: "Aivy" },
      { pattern: /रावी/g, replacement: "Aivy" },
      { pattern: /\baivi\b/gi, replacement: "Aivy" },
      { pattern: /\baavi\b/gi, replacement: "Aivy" },
    ];

    let correctedQuestion = question;
    for (const correction of nameCorrections) {
      correctedQuestion = correctedQuestion.replace(correction.pattern, correction.replacement);
    }
    question = correctedQuestion;

    // Block scheduling/action intents on Voice Home — redirect to Chat
    const qLower = question.toLowerCase();
    
    // Google Search Intent Detection
    const searchKeywords = [
      "google search", "google pe search", "google par search", "web search", "search on google",
      "find on web", "internet se", "net pe", "net par", "google karo", "google kr", "google se"
    ];
    const isSearchRequested = searchKeywords.some(kw => qLower.includes(kw));
    let searchResults: SearchResultItem[] | undefined;

    if (isSearchRequested) {
      let searchQuery = question;
      const prefixes = [
        /^\b(google search|google pe search|google par search|web search|search on google|find on web|internet se|net pe|net par|google karo|google kr|google se)\b/gi,
        /\b(google search|google pe search|google par search|web search|search on google|find on web|internet se|net pe|net par|google karo|google kr|google se)$/gi,
      ];
      for (const prefix of prefixes) {
        searchQuery = searchQuery.replace(prefix, "");
      }
      searchQuery = searchQuery.trim() || question;

      logger.info("Voice Home: Web search detected", { original: question, query: searchQuery });
      const searchResponse = await runWebSearch(searchQuery);
      if (searchResponse.success && searchResponse.results.length > 0) {
        searchResults = searchResponse.results;
      }
    }

    if (
      looksLikeReminderSchedulingLine(qLower, question) &&
      !isWhoToCallAnalyticsQuestionText(question)
    ) {
      const blockWritten = "Sir, mai aapko aapke schedule ke baare me bata sakti hu ya aur koi jankari chahiye to de sakti hu. Is kaam ke liye aap chat section me jaaye.";
      const blockSpoken = "सर, मैं आपको आपके शेड्यूल के बारे में बता सकती हूँ या और कोई जानकारी चाहिए तो दे सकती हूँ। इस काम के लिए आप चैट सेक्शन में जाएँ।";
      let ttsAudioUrl: string | undefined;
      try {
        ttsAudioUrl = await synthesizeToFirebaseStorage({ uid, text: blockSpoken });
      } catch (e) {
        logger.warn("aivyVoiceAsk block TTS failed", {
          err: e instanceof Error ? e.message : String(e),
        });
      }
      return {
        answer: blockWritten,
        transcript: question,
        ttsAudioUrl,
      };
    }

    // Gemini reads Devanagari natively, so the answer must not wait on
    // romanization — that call only prettifies the transcript we echo back.
    // Running them together removes a full LLM round trip from every turn.
    const [result, romanizedTranscript] = await Promise.all([
      answerVoiceQuestion({
        geminiKey,
        question,
        snapshot,
        tc,
        history: body.history,
        searchResults,
      }),
      romanizeUserFacingText(question, geminiKey),
    ]);

    const answer = result.writtenAnswer;
    const spokenAnswer = result.spokenAnswer;

    // Never fail the whole turn if TTS Storage write fails — client can synthesize.
    let ttsAudioUrl: string | undefined;
    try {
      ttsAudioUrl = await synthesizeToFirebaseStorage({ uid, text: spokenAnswer });
    } catch (e) {
      logger.warn("aivyVoiceAsk TTS failed; returning text-only answer", {
        uid,
        err: e instanceof Error ? e.message : String(e),
      });
    }

    logger.info("aivyVoiceAsk answered", {
      uid,
      questionLen: question.length,
      answerLen: answer.length,
      searched: isSearchRequested,
      hasTts: Boolean(ttsAudioUrl),
    });

    return {
      answer,
      transcript: romanizedTranscript.trim() || question,
      ttsAudioUrl,
      sources: searchResults ? searchResults.map(r => ({ title: r.title, link: r.link })) : undefined,
    };
  },
);

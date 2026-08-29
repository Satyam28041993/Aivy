/**
 * Callables for the agent screen.
 *
 *   aivyAgent        — one conversational turn
 *   aivyAgentCommit  — the user tapped "Sahi hai" on a card
 *   aivyAgentChats   — history: list / rename / delete / new
 *
 * The turn is the whole product: it holds the model, the tools and the
 * conversation, so the Flutter side stays a view over Firestore.
 */

import { HttpsError, onCall } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import { logger } from "firebase-functions";
import { DateTime } from "luxon";

import { runAgentTurn } from "./agentLoop";
import { buildSystemPrompt } from "./systemPrompt";
import { commitDraft } from "./commit";
import { getUserMemory } from "../aivyProcess";
import { listPendingDrafts, markDraftStatus } from "./draftStore";
import {
  appendMessage,
  createChat,
  deleteChat,
  ensureChat,
  listChats,
  loadHistory,
  noteSaved,
  renameChat,
  titleFromText,
  touchChat,
} from "./chatStore";

const geminiApiKey = defineSecret("GEMINI_API_KEY");

const REGION = "us-central1";

/**
 * Bumped whenever these functions need to redeploy for a reason the source
 * hash would not otherwise notice.
 *
 * The Firebase CLI skips a function whose code is unchanged, and skipping also
 * skips setting its invoker IAM policy. The first deploy of these three
 * uploaded their code but failed that IAM step, so every later deploy reported
 * "Skipped (No changes detected)" and never retried it — leaving them
 * unreachable from the browser, which surfaces as a CORS error because the
 * preflight is rejected before it reaches the function.
 */
const AGENT_BUILD = "v3-google";

function requireUid(auth: { uid: string } | undefined): string {
  if (!auth?.uid) {
    throw new HttpsError("unauthenticated", "Sign in required");
  }
  return auth.uid;
}

function str(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

/** Display name for the persona; falls back to something neutral. */
function userNameFrom(memory: Record<string, unknown>, token: Record<string, unknown>): string {
  const fromMemory = str(memory.name) || str(memory.userName);
  if (fromMemory) {
    return fromMemory;
  }
  const fromToken = str(token.name);
  if (fromToken) {
    return fromToken.split(" ")[0]!;
  }
  return "Sir";
}

export const aivyAgent = onCall(
  {
    region: REGION,
    timeoutSeconds: 120,
    memory: "512MiB",
    secrets: [geminiApiKey],
    // A warm instance keeps the first message of a session off the cold-start
    // cliff, which is the single most noticeable delay on this screen.
    minInstances: 0,
  },
  async (request) => {
    const uid = requireUid(request.auth);
    const payload = (request.data ?? {}) as Record<string, unknown>;

    const userText = str(payload.text);
    if (!userText) {
      throw new HttpsError("invalid-argument", "text is required");
    }

    // Google token for this turn only. It is deliberately never written to
    // Firestore or logged — it lives in memory for the length of the call and
    // Google expires it in about an hour anyway. See agent/google/workspace.ts.
    const googleToken = str(payload.googleAccessToken) || null;

    const timezone = str(payload.timezone) || "Asia/Kolkata";
    const nowIso = str(payload.nowIso) || DateTime.now().setZone(timezone).toISO()!;
    const key = geminiApiKey.value() || process.env.GEMINI_API_KEY || "";
    if (!key) {
      throw new HttpsError("failed-precondition", "Gemini key missing");
    }

    const chat = await ensureChat(uid, str(payload.chatId) || null);
    const chatId = chat.id;

    const [memory, history, pending] = await Promise.all([
      getUserMemory(uid).catch(() => ({}) as Record<string, unknown>),
      loadHistory(uid, chatId),
      listPendingDrafts(uid, chatId, 3),
    ]);

    const systemPrompt = buildSystemPrompt({
      userName: userNameFrom(memory, (request.auth?.token ?? {}) as Record<string, unknown>),
      timezone,
      nowLabel: DateTime.fromISO(nowIso, { zone: timezone }).toFormat("cccc, d MMMM yyyy, h:mm a"),
      memory,
      recentlySaved: chat.recentlySaved ?? [],
      pendingDrafts: pending.map((d) => ({
        id: d.id,
        title: d.title,
        summary: d.lines.map((l) => `${l.label}: ${l.value}`).join(", "),
      })),
      googleConnected: googleToken != null,
    });

    await appendMessage(uid, chatId, { role: "user", text: userText });

    let turn;
    try {
      turn = await runAgentTurn({
        ctx: { uid, timezone, nowIso, chatId, googleToken },
        systemPrompt,
        history,
        userText,
        geminiKey: key,
      });
    } catch (e) {
      logger.error("aivyAgent turn failed", {
        uid,
        err: e instanceof Error ? e.message : String(e),
      });
      const sorry = "Abhi kuch gadbad ho gayi — dobara bhejiye.";
      await appendMessage(uid, chatId, { role: "assistant", text: sorry });
      await touchChat(uid, chatId, { lastMessage: sorry });
      return { chatId, reply: sorry, drafts: [], trace: [], failed: true };
    }

    const messageId = await appendMessage(uid, chatId, {
      role: "assistant",
      text: turn.reply,
      drafts: turn.drafts,
      modelParts: turn.newContents,
    });

    await touchChat(uid, chatId, {
      lastMessage: turn.reply,
      ...(chat.lastMessage ? {} : { title: titleFromText(userText) }),
    });

    logger.info("aivyAgent turn", {
      build: AGENT_BUILD,
      uid,
      chatId,
      hops: turn.hops,
      google: googleToken != null,
      tools: turn.trace.map((t) => `${t.name}:${t.ok ? "ok" : t.reason}`),
      drafts: turn.drafts.length,
    });

    return {
      chatId,
      messageId,
      reply: turn.reply,
      drafts: turn.drafts,
      trace: turn.trace,
      failed: false,
    };
  },
);

export const aivyAgentCommit = onCall(
  { region: REGION, timeoutSeconds: 60, memory: "256MiB" },
  async (request) => {
    const uid = requireUid(request.auth);
    const payload = (request.data ?? {}) as Record<string, unknown>;
    const draftId = str(payload.draftId);
    if (!draftId) {
      throw new HttpsError("invalid-argument", "draftId is required");
    }

    // Dismissing a card is a local decision, not a conversation — routing it
    // through the model would cost a full turn to accomplish nothing.
    if (str(payload.action) === "cancel") {
      await markDraftStatus(uid, draftId, "cancelled");
      return { ok: true, message: "Theek hai, rehne diya.", createdIds: [] };
    }

    const result = await commitDraft(uid, draftId, {
      googleToken: str(payload.googleAccessToken) || null,
    });

    const chatId = str(payload.chatId);
    if (chatId && result.ok) {
      // The next turn needs to know this exists, or "usko" has nothing to bind to.
      await noteSaved(uid, chatId, result.summary);
      await appendMessage(uid, chatId, { role: "assistant", text: result.message });
      await touchChat(uid, chatId, { lastMessage: result.message });
    }

    return {
      ok: result.ok,
      message: result.message,
      createdIds: result.createdIds,
    };
  },
);

export const aivyAgentChats = onCall(
  { region: REGION, timeoutSeconds: 60, memory: "256MiB" },
  async (request) => {
    const uid = requireUid(request.auth);
    const payload = (request.data ?? {}) as Record<string, unknown>;
    const action = str(payload.action) || "list";

    switch (action) {
      case "list":
        return { chats: await listChats(uid) };
      case "new":
        return { chat: await createChat(uid) };
      case "rename": {
        const chatId = str(payload.chatId);
        const title = str(payload.title);
        if (!chatId || !title) {
          throw new HttpsError("invalid-argument", "chatId and title are required");
        }
        await renameChat(uid, chatId, title);
        return { ok: true };
      }
      case "delete": {
        const chatId = str(payload.chatId);
        if (!chatId) {
          throw new HttpsError("invalid-argument", "chatId is required");
        }
        await deleteChat(uid, chatId);
        return { ok: true };
      }
      default:
        throw new HttpsError("invalid-argument", `Unknown action: ${action}`);
    }
  },
);

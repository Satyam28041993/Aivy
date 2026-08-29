/**
 * Conversation storage for the agent screen.
 *
 * Chats live at `users/{uid}/agent_chats/{chatId}` with their turns underneath
 * in `/messages`. The client streams that subcollection, so the callable writes
 * both sides of the turn and the UI updates itself — there is no separate push
 * of the reply.
 *
 * Model-facing history is kept on the message rows (`modelParts`) rather than
 * being rebuilt from display text, because a turn that called tools carries
 * function calls and responses that the display text does not show.
 */

import { FieldValue, getFirestore } from "firebase-admin/firestore";

import type { GeminiContent } from "./agentLoop";
import type { AgentDraft } from "./draftTypes";

/** How many past turns are replayed to the model. */
export const HISTORY_TURNS = 12;
/** Recent saves quoted back in the system prompt so "usko" resolves. */
export const RECENT_SAVED_LIMIT = 6;

export interface AgentChatMeta {
  id: string;
  title: string;
  createdAtMs: number;
  updatedAtMs: number;
  lastMessage: string;
  recentlySaved: string[];
}

function chatsRef(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("agent_chats");
}

function messagesRef(uid: string, chatId: string) {
  return chatsRef(uid).doc(chatId).collection("messages");
}

/** Fresh chat. The title is filled in from the first user line. */
export async function createChat(uid: string, title = "Nayi baat"): Promise<AgentChatMeta> {
  const ref = chatsRef(uid).doc();
  const nowMs = Date.now();
  const meta: AgentChatMeta = {
    id: ref.id,
    title,
    createdAtMs: nowMs,
    updatedAtMs: nowMs,
    lastMessage: "",
    recentlySaved: [],
  };
  await ref.set(meta);
  return meta;
}

export async function getChat(uid: string, chatId: string): Promise<AgentChatMeta | null> {
  const snap = await chatsRef(uid).doc(chatId).get();
  if (!snap.exists) {
    return null;
  }
  return snap.data() as AgentChatMeta;
}

/** Returns the chat, creating it when the client sent no id. */
export async function ensureChat(
  uid: string,
  chatId: string | null,
): Promise<AgentChatMeta> {
  if (chatId) {
    const existing = await getChat(uid, chatId);
    if (existing) {
      return existing;
    }
  }
  return createChat(uid);
}

/** A first line makes a better title than "Nayi baat". */
export function titleFromText(text: string): string {
  const t = text.trim().replace(/\s+/g, " ");
  if (!t) {
    return "Nayi baat";
  }
  return t.length <= 40 ? t : `${t.slice(0, 39)}…`;
}

export interface StoredMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
  createdAtMs: number;
  /** Cards attached to an assistant turn. */
  drafts: AgentDraft[];
  /** Raw model turns, replayed as history. Absent on plain display rows. */
  modelParts: GeminiContent[] | null;
}

/**
 * Firestore rejects `undefined` outright — the whole write throws, which
 * surfaces to the app as a bare INTERNAL with no clue where it came from.
 *
 * Tool results reach this file verbatim inside `modelParts`, and a tool that
 * writes `location: value || undefined` to mean "leave this out" is perfectly
 * reasonable JSON and perfectly fatal here. So the key is dropped at the write
 * boundary rather than trusting every tool, present and future, to remember.
 */
function stripUndefined<T>(value: T): T {
  if (Array.isArray(value)) {
    return value.map((v) => stripUndefined(v)) as unknown as T;
  }
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (v === undefined) {
        continue;
      }
      out[k] = stripUndefined(v);
    }
    return out as T;
  }
  return value;
}

export async function appendMessage(
  uid: string,
  chatId: string,
  msg: {
    role: "user" | "assistant";
    text: string;
    drafts?: AgentDraft[];
    modelParts?: GeminiContent[] | null;
  },
): Promise<string> {
  const ref = messagesRef(uid, chatId).doc();
  await ref.set(
    stripUndefined({
      id: ref.id,
      role: msg.role,
      text: msg.text,
      createdAtMs: Date.now(),
      drafts: msg.drafts ?? [],
      modelParts: msg.modelParts ?? null,
    }),
  );
  return ref.id;
}

export async function touchChat(
  uid: string,
  chatId: string,
  patch: { lastMessage?: string; title?: string; recentlySaved?: string[] },
): Promise<void> {
  const update: Record<string, unknown> = { updatedAtMs: Date.now() };
  if (patch.lastMessage != null) {
    update.lastMessage = patch.lastMessage.slice(0, 200);
  }
  if (patch.title != null) {
    update.title = patch.title;
  }
  if (patch.recentlySaved != null) {
    update.recentlySaved = patch.recentlySaved.slice(-RECENT_SAVED_LIMIT);
  }
  await chatsRef(uid).doc(chatId).update(update);
}

/** Adds one line to the chat's running "what I just saved" list. */
export async function noteSaved(
  uid: string,
  chatId: string,
  summary: string,
): Promise<void> {
  if (!summary.trim()) {
    return;
  }
  await chatsRef(uid).doc(chatId).update({
    recentlySaved: FieldValue.arrayUnion(summary.trim()),
    updatedAtMs: Date.now(),
  });
}

/**
 * Rebuilds the model's view of the conversation, oldest first.
 *
 * Rows that stored `modelParts` are replayed verbatim so tool calls and their
 * responses survive; older or plain rows fall back to their display text.
 */
export async function loadHistory(
  uid: string,
  chatId: string,
  turns = HISTORY_TURNS,
): Promise<GeminiContent[]> {
  const snap = await messagesRef(uid, chatId)
    .orderBy("createdAtMs", "desc")
    .limit(turns * 2)
    .get();

  const rows = snap.docs
    .map((d) => d.data() as StoredMessage)
    .sort((a, b) => a.createdAtMs - b.createdAtMs);

  const out: GeminiContent[] = [];
  for (const row of rows) {
    if (row.modelParts && row.modelParts.length > 0) {
      out.push(...row.modelParts);
      continue;
    }
    if (!row.text?.trim()) {
      continue;
    }
    out.push({
      role: row.role === "user" ? "user" : "model",
      parts: [{ text: row.text }],
    });
  }
  return out;
}

export async function listChats(uid: string, limit = 50): Promise<AgentChatMeta[]> {
  const snap = await chatsRef(uid).orderBy("updatedAtMs", "desc").limit(limit).get();
  return snap.docs.map((d) => d.data() as AgentChatMeta);
}

export async function deleteChat(uid: string, chatId: string): Promise<void> {
  const msgs = await messagesRef(uid, chatId).get();
  const db = getFirestore();
  // Chunked because a batch tops out at 500 writes.
  for (let i = 0; i < msgs.docs.length; i += 400) {
    const batch = db.batch();
    for (const doc of msgs.docs.slice(i, i + 400)) {
      batch.delete(doc.ref);
    }
    await batch.commit();
  }
  await chatsRef(uid).doc(chatId).delete();
}

export async function renameChat(
  uid: string,
  chatId: string,
  title: string,
): Promise<void> {
  const t = title.trim();
  if (!t) {
    return;
  }
  await chatsRef(uid).doc(chatId).update({ title: t.slice(0, 80), updatedAtMs: Date.now() });
}

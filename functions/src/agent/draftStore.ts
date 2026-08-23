/**
 * Persistence for agent write drafts.
 *
 * Drafts live under `users/{uid}/agent_drafts/{id}`. They are short-lived: the
 * user either confirms one (commit turns it into a real record) or leaves it,
 * in which case it just sits there marked pending and is ignored.
 */

import { getFirestore } from "firebase-admin/firestore";

import type { AgentDraft, DraftCardLine, DraftData, DraftKind, DraftStatus } from "./draftTypes";

function draftsRef(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("agent_drafts");
}

export interface CreateDraftInput {
  uid: string;
  kind: DraftKind;
  title: string;
  icon: string;
  lines: DraftCardLine[];
  data: DraftData;
  chatId?: string | null;
}

export async function createDraft(input: CreateDraftInput): Promise<AgentDraft> {
  const ref = draftsRef(input.uid).doc();
  const draft: AgentDraft = {
    id: ref.id,
    kind: input.kind,
    status: "pending",
    title: input.title,
    icon: input.icon,
    lines: input.lines,
    data: input.data,
    chatId: input.chatId ?? null,
    createdAtMs: Date.now(),
    committedAtMs: null,
    resultIds: [],
  };
  await ref.set(draft);
  return draft;
}

export async function getDraft(
  uid: string,
  draftId: string,
): Promise<AgentDraft | null> {
  const snap = await draftsRef(uid).doc(draftId).get();
  if (!snap.exists) {
    return null;
  }
  return snap.data() as AgentDraft;
}

export async function markDraftStatus(
  uid: string,
  draftId: string,
  status: DraftStatus,
  resultIds: string[] = [],
): Promise<void> {
  await draftsRef(uid).doc(draftId).update({
    status,
    committedAtMs: status === "committed" ? Date.now() : null,
    resultIds,
  });
}

/**
 * Replaces a draft's payload in place — used when the user says "12 baje kar do"
 * instead of tapping confirm, so the card updates rather than stacking a second
 * one.
 */
export async function updateDraft(
  uid: string,
  draftId: string,
  patch: {
    title?: string;
    lines?: DraftCardLine[];
    data?: DraftData;
  },
): Promise<void> {
  await draftsRef(uid).doc(draftId).update(patch);
}

/** Pending drafts from this chat, newest first — the agent's "what's on screen". */
export async function listPendingDrafts(
  uid: string,
  chatId: string | null,
  limit = 5,
): Promise<AgentDraft[]> {
  let q = draftsRef(uid).where("status", "==", "pending");
  if (chatId) {
    q = q.where("chatId", "==", chatId);
  }
  const snap = await q.orderBy("createdAtMs", "desc").limit(limit).get();
  return snap.docs.map((d) => d.data() as AgentDraft);
}

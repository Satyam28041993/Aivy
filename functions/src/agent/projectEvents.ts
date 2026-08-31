/**
 * What happened to a project or task, in the order it happened.
 *
 * `updatedAtMs` answers "when was this last touched" and nothing else. The
 * question actually being asked of a tracker is "kab kya update kiya" — when
 * the sample went, when the client came back, when the deadline moved — and
 * that history cannot be reconstructed from current state, because current
 * state is precisely what history has been overwritten into.
 *
 * So every change appends one line here. They are written best-effort: an
 * event that fails to save must never cost the change it was describing, since
 * the change is the thing the user asked for and the note about it is not.
 */

import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";

export type ProjectEventKind =
  | "created"
  | "items_added"
  | "status"
  | "due"
  | "note"
  | "closed";

export interface ProjectEvent {
  id: string;
  atMs: number;
  kind: ProjectEventKind;
  /** One line, already in the words it should be read in. */
  text: string;
}

function eventsRef(uid: string, projectId: string) {
  return getFirestore()
    .collection("users")
    .doc(uid)
    .collection("projects")
    .doc(projectId)
    .collection("events");
}

export async function logProjectEvent(
  uid: string,
  projectId: string,
  kind: ProjectEventKind,
  text: string,
): Promise<void> {
  const line = text.trim();
  if (!projectId || !line) {
    return;
  }
  try {
    const ref = eventsRef(uid, projectId).doc();
    const event: ProjectEvent = { id: ref.id, atMs: Date.now(), kind, text: line };
    await ref.set(event);
  } catch (e) {
    logger.warn("logProjectEvent: could not write", {
      projectId,
      kind,
      err: e instanceof Error ? e.message : String(e),
    });
  }
}

/** Newest first, which is how a history is read when you already know the end. */
export async function listProjectEvents(
  uid: string,
  projectId: string,
  limit = 100,
): Promise<ProjectEvent[]> {
  const snap = await eventsRef(uid, projectId).limit(limit).get();
  return snap.docs
    .map((d) => d.data() as ProjectEvent)
    .sort((a, b) => b.atMs - a.atMs);
}

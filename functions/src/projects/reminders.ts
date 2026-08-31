import type { ProjectDraftItem, ProjectItemRecord } from "./types";

/** Dated project items become reminders through the existing notifications path. */
export function reminderPayloadForItem(
  item: Pick<
    ProjectDraftItem | ProjectItemRecord,
    "title" | "kind" | "status" | "waitingOn" | "notes" | "dueAtMs"
  >,
  projectName: string,
  client: string,
): {
  title: string;
  type: string;
  subType: string;
  note: string;
  clientName: string;
  isFollowUp: boolean;
} | null {
  if (item.dueAtMs == null || !Number.isFinite(item.dueAtMs)) {
    return null;
  }
  const who = item.waitingOn.trim();
  const title =
    item.status === "waiting_on_them"
      ? who
        ? `${projectName}: ${who} se ${item.title}`
        : `${projectName}: ${item.title} (waiting on them)`
      : `${projectName}: ${item.title}`;
  const noteBits = [item.notes.trim(), item.kind !== "general" ? item.kind : ""]
    .filter(Boolean);
  return {
    title,
    type: item.status === "waiting_on_them" || item.kind === "followup"
      ? "followup"
      : "task",
    subType: "project_item",
    note: noteBits.join(" · "),
    clientName: client.trim() || projectName,
    isFollowUp: item.status === "waiting_on_them" || item.kind === "followup",
  };
}

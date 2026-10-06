/**
 * delete_record and restore_deleted.
 *
 * The user asked for Aivy to delete anything they ask it to, "but proper
 * confirmation se". So: find exactly one record (several matches → ask which,
 * none → say so), draw a card naming it and what goes with it, delete only on
 * confirm, and keep a copy in trash so a mistake can be undone.
 */

import { DateTime } from "luxon";

import { createDraft } from "../draftStore";
import { resolveWhen } from "../dateResolve";
import type { DraftCardLine } from "../draftTypes";
import { DELETE_KINDS, findDeleteTargets, isDeleteKind, listTrash, type DeleteKind } from "../deleteStore";
import { dayKey } from "../expenseStore";
import { dataResult, draftResult, fail, type ToolContext, type ToolResult } from "../toolTypes";

function str(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

const KIND_LABEL: Record<DeleteKind, string> = {
  reminder: "Reminder",
  task: "Task",
  project: "Project",
  visit: "Visit (DSR)",
  travel_expense: "Travel expense",
  saved_place: "Saved place",
  occasion: "Birthday / anniversary",
  remembered_fact: "Remembered fact",
  contact: "Contact",
  library_item: "Library document",
  quotation: "Quotation",
  order: "Order",
  payment_due: "Payment due",
};

/** What else goes with it, said plainly on the card. */
function sideEffects(kind: DeleteKind, hasSheet: boolean): string {
  switch (kind) {
    case "task":
    case "project":
      return "Its steps go too, and its reminders are cancelled.";
    case "visit":
      return `Its follow-up reminder is cancelled${hasSheet ? " and its DSR sheet row is cleared" : ""}.`;
    case "travel_expense":
      return hasSheet ? "Its rows in the expense sheet are cleared." : "";
    case "quotation":
      return "Its follow-up reminder is cancelled.";
    case "reminder":
      return "The alarm is cancelled.";
    default:
      return "";
  }
}

export async function deleteRecordTool(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const kind = str(args.kind);
  if (!isDeleteKind(kind)) {
    return fail("needs_detail", `What should be deleted? One of: ${DELETE_KINDS.join(", ")}.`);
  }
  const query = str(args.query);
  const id = str(args.id);
  let day: string | null = null;
  if (kind === "travel_expense" && query && !id) {
    const when = resolveWhen({
      phrase: query,
      timezone: ctx.timezone,
      nowIso: ctx.nowIso,
      tense: "past",
      period: null,
      defaultHour: 12,
    });
    if (when.epochMs != null) day = dayKey(when.epochMs, ctx.timezone);
  }
  if (!query && !id) {
    return fail("needs_detail", `Which ${KIND_LABEL[kind].toLowerCase()}? Give a name, client or date.`);
  }

  const found = await findDeleteTargets(ctx.uid, kind, query, { id: id || undefined, timezone: ctx.timezone, dayKey: day });
  if (found.length === 0) {
    return fail("nothing_found", `No ${KIND_LABEL[kind].toLowerCase()} matches "${query || id}". Say it differently, or check the name.`);
  }
  const all = args.all_matches === true;
  if (found.length > 1 && !all) {
    return fail(
      "needs_detail",
      `${found.length} match. Ask which one (or whether all of them), then call again with its id or all_matches=true.`,
      found.slice(0, 8).map((t) => ({ id: t.memoryKey ?? t.path.split("/").pop()!, label: t.label })),
    );
  }
  const targets = all ? found.slice(0, 20) : found;

  const lines: DraftCardLine[] = targets.map((t, i) => ({
    label: targets.length > 1 ? `${i + 1}.` : KIND_LABEL[kind],
    value: t.label,
  }));
  const effect = sideEffects(kind, targets.some((t) => t.sheetRows));
  if (effect) lines.push({ label: "Also", value: effect });
  lines.push({ label: "Undo", value: "A copy is kept in trash — say \"wapas lao\" to bring it back." });

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "delete_record",
    title: targets.length > 1 ? `Delete ${targets.length} items` : "Delete",
    icon: "🗑️",
    lines,
    chatId: ctx.chatId,
    data: { kind: "delete_record", targets, timezone: ctx.timezone },
  });
  return draftResult(
    draft,
    "Delete card ready. Nothing is deleted until they confirm — ask them to check it is the right one.",
  );
}

export async function restoreDeletedTool(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const trash = (await listTrash(ctx.uid, 15)).filter((t) => !t.restored);
  if (trash.length === 0) {
    return fail("nothing_found", "Nothing deleted is waiting in trash.");
  }
  const id = str(args.trash_id);
  const query = str(args.query).toLowerCase();
  const pickOne = id
    ? trash.find((t) => t.id === id)
    : query
      ? trash.find((t) => `${t.label} ${t.kind}`.toLowerCase().includes(query))
      : trash[0];
  if (!pickOne) {
    return fail(
      "needs_detail",
      "Which one should come back?",
      trash.slice(0, 8).map((t) => ({ id: t.id, label: `${t.label} (${t.kind})` })),
    );
  }
  const when = DateTime.fromMillis(pickOne.deletedAtMs, { zone: ctx.timezone }).toFormat("d LLL, h:mm a");
  const draft = await createDraft({
    uid: ctx.uid,
    kind: "restore_deleted",
    title: "Bring back",
    icon: "♻️",
    lines: [
      { label: pickOne.kind.replace(/_/g, " "), value: pickOne.label },
      { label: "Deleted", value: when },
    ],
    chatId: ctx.chatId,
    data: { kind: "restore_deleted", trashId: pickOne.id, label: pickOne.label },
  });
  return draftResult(draft, "Restore card ready — ask them to confirm.");
}

export async function listTrashTool(ctx: ToolContext): Promise<ToolResult> {
  const trash = await listTrash(ctx.uid, 15);
  return dataResult({
    deleted: trash.map((t) => ({
      trash_id: t.id,
      what: t.kind,
      label: t.label,
      deleted: DateTime.fromMillis(t.deletedAtMs, { zone: ctx.timezone }).toFormat("d LLL, h:mm a"),
      restored: t.restored,
    })),
  });
}

/**
 * The contract between a tool and the model.
 *
 * Every tool returns one of these as JSON. The model reads it and decides what
 * to say — so failures are not errors to be swallowed, they are information the
 * agent can act on ("kaunsa Rohan?" / "kitna amount?").
 */

import type { AgentDraft } from "./draftTypes";

export interface ToolDraftResult {
  ok: true;
  kind: "draft";
  /** Rendered by the client as a confirm card; nothing is saved yet. */
  draft: AgentDraft;
  /** Short nudge for the model, e.g. "draft ready, confirm maango". */
  hint: string;
}

export interface ToolDataResult {
  ok: true;
  kind: "data";
  data: unknown;
}

export type ToolFailureReason =
  | "needs_client_choice"
  | "client_not_found"
  | "needs_date"
  | "needs_amount"
  | "needs_detail"
  | "nothing_found"
  | "invalid"
  | "failed";

export interface ToolFailureResult {
  ok: false;
  reason: ToolFailureReason;
  /** Plain sentence the model can turn into its own question. */
  message: string;
  /** Choices to put to the user, when the failure is an ambiguity. */
  options?: Array<{ id: string; label: string }>;
}

export type ToolResult = ToolDraftResult | ToolDataResult | ToolFailureResult;

export function draftResult(draft: AgentDraft, hint: string): ToolDraftResult {
  return { ok: true, kind: "draft", draft, hint };
}

export function dataResult(data: unknown): ToolDataResult {
  return { ok: true, kind: "data", data };
}

export function fail(
  reason: ToolFailureReason,
  message: string,
  options?: Array<{ id: string; label: string }>,
): ToolFailureResult {
  return { ok: false, reason, message, ...(options ? { options } : {}) };
}

/** Context every tool call receives. */
export interface ToolContext {
  uid: string;
  timezone: string;
  nowIso: string;
  chatId: string | null;
}

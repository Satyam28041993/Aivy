/**
 * The agent loop: model → tool → model → … → reply.
 *
 * The model is given the tool declarations and left to decide. That is the whole
 * point of the rewrite — there is no intent classifier here, no keyword gate, no
 * routing table. If the model wants data it asks for data; if it wants to record
 * something it proposes a draft.
 *
 * The loop is bounded (`maxHops`) so a model that keeps calling tools cannot run
 * forever, and the transport is injectable so the loop can be tested without a
 * network or an API key.
 */

import { logger } from "firebase-functions";

import type { AgentDraft } from "./draftTypes";
import { dispatchTool, isKnownTool, TOOL_DECLARATIONS, WRITE_TOOLS } from "./toolRegistry";
import type { ToolContext } from "./toolTypes";

const MODEL = "gemini-2.5-flash";
const ENDPOINT = `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`;

export interface GeminiPart {
  text?: string;
  functionCall?: { name: string; args?: Record<string, unknown> };
  functionResponse?: { name: string; response: Record<string, unknown> };
}

export interface GeminiContent {
  role: "user" | "model";
  parts: GeminiPart[];
}

export interface GeminiRequest {
  systemInstruction: { parts: Array<{ text: string }> };
  contents: GeminiContent[];
  tools: Array<{ functionDeclarations: typeof TOOL_DECLARATIONS }>;
  generationConfig: Record<string, unknown>;
}

export interface GeminiResponse {
  candidates?: Array<{
    content?: { parts?: GeminiPart[] };
    finishReason?: string;
  }>;
}

/** Swappable so tests can drive the loop with a scripted model. */
export type GeminiTransport = (req: GeminiRequest) => Promise<GeminiResponse>;

export interface AgentTurnInput {
  ctx: ToolContext;
  systemPrompt: string;
  /** Prior turns, oldest first. */
  history: GeminiContent[];
  userText: string;
  maxHops?: number;
  transport?: GeminiTransport;
  geminiKey?: string;
}

export interface AgentToolTrace {
  name: string;
  args: Record<string, unknown>;
  ok: boolean;
  /** Present for failures, so the client log shows why. */
  reason?: string;
}

export interface AgentTurnResult {
  reply: string;
  /** Cards to render — one per successful write tool call. */
  drafts: AgentDraft[];
  /** What the tools did, in order. */
  trace: AgentToolTrace[];
  /** Model-visible turns to persist as history for the next call. */
  newContents: GeminiContent[];
  hops: number;
}

function httpTransport(geminiKey: string): GeminiTransport {
  return async (req) => {
    const body = JSON.stringify(req);
    let lastErr: unknown;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const res = await fetch(ENDPOINT, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-goog-api-key": geminiKey,
          },
          body,
        });
        if (!res.ok) {
          const text = await res.text();
          throw new Error(`Gemini ${res.status}: ${text.slice(0, 300)}`);
        }
        return (await res.json()) as GeminiResponse;
      } catch (e) {
        lastErr = e;
        if (attempt === 1) {
          throw e;
        }
        logger.warn("agent: Gemini call failed, retrying", {
          err: e instanceof Error ? e.message : String(e),
        });
      }
    }
    throw lastErr;
  };
}

function partsOf(res: GeminiResponse): GeminiPart[] {
  return res.candidates?.[0]?.content?.parts ?? [];
}

function textOf(parts: GeminiPart[]): string {
  return parts
    .map((p) => (typeof p.text === "string" ? p.text : ""))
    .join("")
    .trim();
}

function callsOf(parts: GeminiPart[]): Array<{ name: string; args: Record<string, unknown> }> {
  const out: Array<{ name: string; args: Record<string, unknown> }> = [];
  for (const p of parts) {
    if (p.functionCall?.name) {
      out.push({ name: p.functionCall.name, args: p.functionCall.args ?? {} });
    }
  }
  return out;
}

/**
 * Trims a tool result before it goes back to the model. A draft's full payload
 * is large and the model only needs to know it worked and what it says, so the
 * card lines go back instead of the whole record.
 */
function toolResponseForModel(result: Awaited<ReturnType<typeof dispatchTool>>): Record<string, unknown> {
  if (!result.ok) {
    return {
      ok: false,
      reason: result.reason,
      message: result.message,
      ...(result.options ? { options: result.options } : {}),
    };
  }
  if (result.kind === "draft") {
    return {
      ok: true,
      draft_id: result.draft.id,
      saved: false,
      card: {
        title: result.draft.title,
        lines: result.draft.lines,
      },
      hint: result.hint,
    };
  }
  return { ok: true, data: result.data };
}

/** Runs one user turn to completion. */
export async function runAgentTurn(input: AgentTurnInput): Promise<AgentTurnResult> {
  const maxHops = input.maxHops ?? 5;
  const transport =
    input.transport ??
    httpTransport(
      input.geminiKey ?? (() => {
        throw new Error("Gemini key missing");
      })(),
    );

  const contents: GeminiContent[] = [
    ...input.history,
    { role: "user", parts: [{ text: input.userText }] },
  ];
  // Everything produced this turn, for persisting as history.
  const newContents: GeminiContent[] = [
    { role: "user", parts: [{ text: input.userText }] },
  ];

  const drafts: AgentDraft[] = [];
  const trace: AgentToolTrace[] = [];
  let reply = "";
  let hops = 0;

  while (hops < maxHops) {
    // Snapshot: `contents` keeps growing as the loop runs, and a transport that
    // logs or retries asynchronously must not see it change underneath it.
    const res = await transport({
      systemInstruction: { parts: [{ text: input.systemPrompt }] },
      contents: contents.map((c) => ({ role: c.role, parts: [...c.parts] })),
      tools: [{ functionDeclarations: TOOL_DECLARATIONS }],
      generationConfig: { temperature: 0.7, maxOutputTokens: 2048 },
    });
    hops++;

    const parts = partsOf(res);
    const calls = callsOf(parts);
    const text = textOf(parts);

    if (calls.length === 0) {
      reply = text;
      if (text) {
        const modelTurn: GeminiContent = { role: "model", parts: [{ text }] };
        contents.push(modelTurn);
        newContents.push(modelTurn);
      }
      break;
    }

    // Keep the model's own turn (including the calls) so the next hop has it.
    const modelTurn: GeminiContent = { role: "model", parts };
    contents.push(modelTurn);
    newContents.push(modelTurn);

    const responseParts: GeminiPart[] = [];
    for (const call of calls) {
      if (!isKnownTool(call.name)) {
        responseParts.push({
          functionResponse: {
            name: call.name,
            response: { ok: false, reason: "invalid", message: "Unknown tool" },
          },
        });
        trace.push({ name: call.name, args: call.args, ok: false, reason: "invalid" });
        continue;
      }

      const result = await dispatchTool(call.name, input.ctx, call.args);
      trace.push({
        name: call.name,
        args: call.args,
        ok: result.ok,
        ...(result.ok ? {} : { reason: result.reason }),
      });

      if (result.ok && result.kind === "draft" && WRITE_TOOLS.has(call.name)) {
        drafts.push(result.draft);
      }

      responseParts.push({
        functionResponse: { name: call.name, response: toolResponseForModel(result) },
      });
    }

    const toolTurn: GeminiContent = { role: "user", parts: responseParts };
    contents.push(toolTurn);
    newContents.push(toolTurn);

    // Any text alongside the calls is a running commentary; keep the last one as
    // a fallback in case the hop budget runs out before a clean reply.
    if (text) {
      reply = text;
    }
  }

  if (!reply) {
    reply = drafts.length
      ? "Ye taiyaar hai — dekh lijiye, sahi ho to confirm kar dijiye."
      : "Samajh nahi paayi, thoda aur bataiye?";
  }

  return { reply, drafts, trace, newContents, hops };
}

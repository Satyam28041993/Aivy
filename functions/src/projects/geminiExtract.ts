import { logger } from "firebase-functions";

import { clockToDateTime } from "./dates";
import { heuristicExtractDraft, normalizeDraftItem } from "./extract";
import type { ProjectClock, ProjectDraftPayload } from "./types";

const GEMINI_ENDPOINT =
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent";

function extractJsonObject(raw: string): Record<string, unknown> | null {
  const trimmed = raw.trim();
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const body = (fenced?.[1] ?? trimmed).trim();
  const start = body.indexOf("{");
  const end = body.lastIndexOf("}");
  if (start < 0 || end <= start) {
    return null;
  }
  try {
    const parsed = JSON.parse(body.slice(start, end + 1)) as unknown;
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
  } catch {
    return null;
  }
  return null;
}

function buildExtractPrompt(text: string, clock: ProjectClock): string {
  const now = clockToDateTime(clock);
  return `You extract flexible project work items from messy Hinglish business notes.
There is NO fixed pipeline (not sample→approval→rate→PO). Create only the items the user actually mentioned.

User timezone: ${clock.timezone || "UTC"}
Now: ${now.toISO()}

Return ONLY JSON:
{
  "projectName": "short name (place or client or both)",
  "client": "client / person if any",
  "items": [
    {
      "title": "short what-to-do",
      "description": "original clause",
      "kind": "sample|approval|rate|meeting|followup|general",
      "status": "pending|waiting_on_them|done|cancelled",
      "dueAtIso": "ISO-8601 with offset or null",
      "waitingOn": "person/role on the client side, else empty",
      "notes": "optional extra"
    }
  ]
}

Rules:
- kind is a hint, not a required schema. Use general if unsure.
- waiting_on_them = client's side (their approval, their rate, their PO, their QC). User's own next action stays pending.
- Clock-time fidelity: if they said 4pm, dueAtIso must be 16:00 in their timezone, never 11:00.
- If only a day is given (Monday, 5 tarikh) and no clock, use 11:00 local.
- Split into separate items when there are distinct actions.
- Do not invent clients, dates, or items.

User notes:
${text}`;
}

export async function extractDraftWithGemini(opts: {
  text: string;
  clock: ProjectClock;
  geminiKey: string;
}): Promise<ProjectDraftPayload> {
  const fallback = heuristicExtractDraft(opts.text, opts.clock);
  const key = opts.geminiKey.trim();
  if (!key) {
    return fallback;
  }
  try {
    const response = await fetch(GEMINI_ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-goog-api-key": key,
      },
      body: JSON.stringify({
        contents: [
          {
            role: "user",
            parts: [{ text: buildExtractPrompt(opts.text, opts.clock) }],
          },
        ],
      }),
    });
    if (!response.ok) {
      logger.warn("project extract Gemini HTTP error", { status: response.status });
      return fallback;
    }
    const data = (await response.json()) as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
    };
    const raw =
      data.candidates?.[0]?.content?.parts
        ?.map((p) => (typeof p.text === "string" ? p.text : ""))
        .join("") ?? "";
    const parsed = extractJsonObject(raw);
    if (!parsed) {
      return fallback;
    }
    const itemsRaw = Array.isArray(parsed.items) ? parsed.items : [];
    const items = itemsRaw
      .map((row) => {
        if (!row || typeof row !== "object") {
          return null;
        }
        return normalizeDraftItem(row as Record<string, string>, opts.clock);
      })
      .filter((x): x is NonNullable<typeof x> => x != null);
    if (items.length === 0) {
      return fallback;
    }
    const projectName =
      typeof parsed.projectName === "string" && parsed.projectName.trim()
        ? parsed.projectName.trim()
        : fallback.projectName;
    const client =
      typeof parsed.client === "string" && parsed.client.trim()
        ? parsed.client.trim()
        : fallback.client;
    return {
      ...fallback,
      projectName,
      client,
      items,
    };
  } catch (e) {
    logger.warn("project extract Gemini failed", {
      err: e instanceof Error ? e.message : String(e),
    });
    return fallback;
  }
}

import { beforeEach, describe, expect, it, vi } from "vitest";

import type { ToolContext } from "./toolTypes";

// The loop is exercised against a scripted model, so these tests cover the
// mechanics — hop budget, tool dispatch, history shape, draft collection —
// without a network call or an API key.
const dispatchMock = vi.fn();

vi.mock("./toolRegistry", async () => {
  const actual = await vi.importActual<typeof import("./toolRegistry")>("./toolRegistry");
  return {
    ...actual,
    dispatchTool: (...args: unknown[]) => dispatchMock(...args),
  };
});

const { runAgentTurn } = await import("./agentLoop");
type GeminiResponse = import("./agentLoop").GeminiResponse;

const CTX: ToolContext = {
  uid: "u1",
  timezone: "Asia/Kolkata",
  nowIso: "2025-08-23T14:30:00+05:30",
  chatId: "c1",
};

function say(text: string): GeminiResponse {
  return { candidates: [{ content: { parts: [{ text }] } }] };
}

function call(name: string, args: Record<string, unknown> = {}, text?: string): GeminiResponse {
  const parts = [];
  if (text) parts.push({ text });
  parts.push({ functionCall: { name, args } });
  return { candidates: [{ content: { parts } }] };
}

function scripted(...responses: GeminiResponse[]) {
  let i = 0;
  const seen: unknown[] = [];
  const transport = async (req: unknown) => {
    seen.push(req);
    return responses[Math.min(i++, responses.length - 1)]!;
  };
  return { transport, seen, calls: () => i };
}

function draftOk(id = "d1", title = "Meeting") {
  return {
    ok: true as const,
    kind: "draft" as const,
    draft: {
      id,
      kind: "meeting",
      status: "pending",
      title,
      icon: "📅",
      lines: [{ label: "Kab", value: "Ravivar, 24 August, 11:00 AM" }],
      data: { kind: "meeting" },
      chatId: "c1",
      createdAtMs: 0,
      committedAtMs: null,
      resultIds: [],
    },
    hint: "confirm maango",
  };
}

function dataOk(data: unknown) {
  return { ok: true as const, kind: "data" as const, data };
}

const base = { ctx: CTX, systemPrompt: "sys", history: [] };

beforeEach(() => {
  dispatchMock.mockReset();
});

describe("plain conversation", () => {
  it("returns the model's text without touching any tool", async () => {
    const s = scripted(say("Arre bore ho rahe ho? Batao kya chal raha hai."));
    const res = await runAgentTurn({
      ...base,
      userText: "aivy yaar main bore ho raha hu",
      transport: s.transport,
    });

    expect(res.reply).toContain("bore");
    expect(res.trace).toHaveLength(0);
    expect(res.drafts).toHaveLength(0);
    expect(dispatchMock).not.toHaveBeenCalled();
    expect(res.hops).toBe(1);
  });

  it("sends the system prompt and the user turn to the model", async () => {
    const s = scripted(say("ok"));
    await runAgentTurn({ ...base, userText: "hello", transport: s.transport });
    const req = s.seen[0] as {
      systemInstruction: { parts: Array<{ text: string }> };
      contents: Array<{ role: string; parts: Array<{ text?: string }> }>;
      tools: Array<{ functionDeclarations: unknown[] }>;
    };
    expect(req.systemInstruction.parts[0]!.text).toBe("sys");
    expect(req.contents.at(-1)!.parts[0]!.text).toBe("hello");
    expect(req.tools[0]!.functionDeclarations.length).toBeGreaterThan(10);
  });
});

describe("a single tool call", () => {
  it("dispatches, feeds the result back and returns the follow-up reply", async () => {
    dispatchMock.mockResolvedValue(dataOk({ count: 2, items: [] }));
    const s = scripted(
      call("get_agenda", { window: "today" }),
      say("Aaj do log hain — Rohan aur Karan."),
    );

    const res = await runAgentTurn({
      ...base,
      userText: "aaj kisko call karna hai",
      transport: s.transport,
    });

    expect(dispatchMock).toHaveBeenCalledTimes(1);
    expect(dispatchMock.mock.calls[0]![0]).toBe("get_agenda");
    expect(dispatchMock.mock.calls[0]![2]).toEqual({ window: "today" });
    expect(res.reply).toContain("Rohan");
    expect(res.trace).toEqual([
      { name: "get_agenda", args: { window: "today" }, ok: true },
    ]);
    expect(res.hops).toBe(2);
  });

  it("passes the tool response back as a functionResponse part", async () => {
    dispatchMock.mockResolvedValue(dataOk({ count: 0 }));
    const s = scripted(call("get_agenda", {}), say("Kuch nahi hai aaj."));
    await runAgentTurn({ ...base, userText: "aaj kya hai", transport: s.transport });

    const second = s.seen[1] as { contents: Array<{ role: string; parts: unknown[] }> };
    const toolTurn = second.contents.at(-1) as {
      parts: Array<{ functionResponse?: { name: string; response: Record<string, unknown> } }>;
    };
    expect(toolTurn.parts[0]!.functionResponse!.name).toBe("get_agenda");
    expect(toolTurn.parts[0]!.functionResponse!.response.ok).toBe(true);
  });
});

describe("write tools produce cards", () => {
  it("collects the draft and reports it as unsaved to the model", async () => {
    dispatchMock.mockResolvedValue(draftOk("d1", "Meeting"));
    const s = scripted(
      call("create_meeting", { when_phrase: "kal 11 baje" }),
      say("Meeting taiyaar hai — confirm kar dijiye."),
    );

    const res = await runAgentTurn({
      ...base,
      userText: "kal 11 baje rohan ke sath meeting hai",
      transport: s.transport,
    });

    expect(res.drafts).toHaveLength(1);
    expect(res.drafts[0]!.id).toBe("d1");

    const second = s.seen[1] as { contents: Array<{ parts: unknown[] }> };
    const toolTurn = second.contents.at(-1) as {
      parts: Array<{ functionResponse?: { response: Record<string, unknown> } }>;
    };
    const response = toolTurn.parts[0]!.functionResponse!.response;
    // The model must know this is not saved yet, or it will claim it is done.
    expect(response.saved).toBe(false);
    expect(response.draft_id).toBe("d1");
  });

  it("does not treat a read tool result as a card", async () => {
    dispatchMock.mockResolvedValue(dataOk({ count: 1 }));
    const s = scripted(call("find_records", { type: "quotation" }), say("Ek mila."));
    const res = await runAgentTurn({ ...base, userText: "kisko quotation diya", transport: s.transport });
    expect(res.drafts).toHaveLength(0);
  });
});

describe("several tools in one turn", () => {
  it("runs every call the model makes together", async () => {
    dispatchMock
      .mockResolvedValueOnce(draftOk("d_quote", "Quotation"))
      .mockResolvedValueOnce(draftOk("d_meet", "Meeting"));

    const s = scripted(
      {
        candidates: [
          {
            content: {
              parts: [
                { functionCall: { name: "record_quotation", args: { client_name: "rohan", amount: 50000 } } },
                { functionCall: { name: "create_meeting", args: { when_phrase: "kal 11 baje" } } },
              ],
            },
          },
        ],
      },
      say("Dono taiyaar hain."),
    );

    const res = await runAgentTurn({
      ...base,
      userText: "rohan ko 50000 ka quotation diya, aur kal 11 baje uske sath meeting bhi hai",
      transport: s.transport,
    });

    expect(dispatchMock).toHaveBeenCalledTimes(2);
    expect(res.drafts.map((d) => d.id)).toEqual(["d_quote", "d_meet"]);
    expect(res.trace).toHaveLength(2);
  });
});

describe("tool failures", () => {
  it("hands the failure to the model instead of throwing", async () => {
    dispatchMock.mockResolvedValue({
      ok: false,
      reason: "needs_client_choice",
      message: "kaunsa Rohan?",
      options: [
        { id: "a", label: "Rohan Traders" },
        { id: "b", label: "Rohan Prints" },
      ],
    });
    const s = scripted(
      call("record_quotation", { client_name: "rohan", amount: 5 }),
      say("Kaunsa Rohan — Traders ya Prints?"),
    );

    const res = await runAgentTurn({ ...base, userText: "rohan ko quotation diya", transport: s.transport });

    expect(res.reply).toContain("Kaunsa Rohan");
    expect(res.drafts).toHaveLength(0);
    expect(res.trace[0]).toMatchObject({ ok: false, reason: "needs_client_choice" });

    const second = s.seen[1] as { contents: Array<{ parts: unknown[] }> };
    const toolTurn = second.contents.at(-1) as {
      parts: Array<{ functionResponse?: { response: Record<string, unknown> } }>;
    };
    expect(toolTurn.parts[0]!.functionResponse!.response.options).toHaveLength(2);
  });

  it("rejects a tool name it does not know without dispatching", async () => {
    const s = scripted(call("delete_everything", {}), say("Wo main nahi kar sakti."));
    const res = await runAgentTurn({ ...base, userText: "sab uda do", transport: s.transport });
    expect(dispatchMock).not.toHaveBeenCalled();
    expect(res.trace[0]).toMatchObject({ name: "delete_everything", ok: false });
  });
});

describe("hop budget", () => {
  it("stops after maxHops even if the model keeps calling tools", async () => {
    dispatchMock.mockResolvedValue(dataOk({}));
    const s = scripted(call("get_agenda", {}));
    const res = await runAgentTurn({
      ...base,
      userText: "loop",
      transport: s.transport,
      maxHops: 3,
    });
    expect(s.calls()).toBe(3);
    expect(res.hops).toBe(3);
    expect(res.reply).toBeTruthy();
  });

  it("falls back to a sensible line when the model never speaks", async () => {
    dispatchMock.mockResolvedValue(draftOk());
    const s = scripted(call("create_meeting", {}));
    const res = await runAgentTurn({ ...base, userText: "meeting", transport: s.transport, maxHops: 2 });
    expect(res.reply).toContain("confirm");
  });
});

describe("history", () => {
  it("carries prior turns into the request", async () => {
    const s = scripted(say("haan"));
    await runAgentTurn({
      ...base,
      history: [
        { role: "user", parts: [{ text: "pehla sawaal" }] },
        { role: "model", parts: [{ text: "pehla jawaab" }] },
      ],
      userText: "aur?",
      transport: s.transport,
    });
    const req = s.seen[0] as { contents: Array<{ parts: Array<{ text?: string }> }> };
    expect(req.contents).toHaveLength(3);
    expect(req.contents[0]!.parts[0]!.text).toBe("pehla sawaal");
  });

  it("returns only this turn's contents for persisting", async () => {
    const s = scripted(say("theek hai"));
    const res = await runAgentTurn({
      ...base,
      history: [{ role: "user", parts: [{ text: "purana" }] }],
      userText: "naya",
      transport: s.transport,
    });
    expect(res.newContents).toHaveLength(2);
    expect(res.newContents[0]!.parts[0]!.text).toBe("naya");
    expect(res.newContents[1]!.role).toBe("model");
  });
});

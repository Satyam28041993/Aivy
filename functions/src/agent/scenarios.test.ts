import { beforeEach, describe, expect, it, vi } from "vitest";

import type { DraftData } from "./draftTypes";
import type { ToolContext } from "./toolTypes";

/**
 * End-to-end walkthrough of the scenarios that motivated this screen.
 *
 * The model is scripted (so these are deterministic and need no API key), but
 * everything below it is the real thing: the real tool registry, the real write
 * tools, the real date resolver and the real client resolution. Only Firestore
 * is stubbed.
 *
 * The point is to prove the wiring end to end — that "kal 11 baje" reaches the
 * resolver as a phrase and comes back as 11 AM on a card, that a question does
 * not create a record, and that one sentence can produce two.
 */

const createdDrafts: Array<Record<string, unknown>> = [];
const resolveClientMock = vi.fn();

/**
 * Collection-aware stub. Keeping the collections apart matters: a payment row
 * carries `dueDateMs`, which the reminder reader legitimately falls back to for
 * legacy rows, so a stub that returned the same docs everywhere would count
 * dues as reminders and quietly invalidate the assertions.
 */
const collectionDocs: Record<string, unknown[]> = {};

function setDocs(collection: string, docs: unknown[]): void {
  collectionDocs[collection] = docs;
}

vi.mock("./draftStore", () => ({
  createDraft: (input: Record<string, unknown>) => {
    const draft = {
      id: `draft_${createdDrafts.length + 1}`,
      status: "pending",
      createdAtMs: 0,
      committedAtMs: null,
      resultIds: [],
      ...input,
    };
    createdDrafts.push(draft);
    return Promise.resolve(draft);
  },
  listPendingDrafts: () => Promise.resolve([]),
  markDraftStatus: () => Promise.resolve(),
  getDraft: () => Promise.resolve(null),
  updateDraft: () => Promise.resolve(),
}));

vi.mock("./clientResolve", async () => {
  const actual = await vi.importActual<typeof import("./clientResolve")>("./clientResolve");
  return { ...actual, resolveClient: (...a: unknown[]) => resolveClientMock(...a) };
});

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: () => ({
      doc: () => ({
        collection: (name: string) => ({
          get: () => Promise.resolve({ docs: collectionDocs[name] ?? [] }),
        }),
      }),
    }),
  }),
  FieldValue: { serverTimestamp: () => "ts" },
}));

vi.mock("../webSearch", () => ({
  runWebSearch: (q: string) =>
    Promise.resolve({
      query: q,
      success: true,
      results: [
        { title: "Result one", link: "https://example.com/1", snippet: "First snippet." },
      ],
    }),
}));

const { runAgentTurn } = await import("./agentLoop");
type GeminiResponse = import("./agentLoop").GeminiResponse;

const CTX: ToolContext = {
  uid: "u1",
  timezone: "Asia/Kolkata",
  // Saturday 23 August 2025, 14:30 IST.
  nowIso: "2025-08-23T14:30:00+05:30",
  chatId: "c1",
};

function say(text: string): GeminiResponse {
  return { candidates: [{ content: { parts: [{ text }] } }] };
}

function calls(...fns: Array<{ name: string; args: Record<string, unknown> }>): GeminiResponse {
  return {
    candidates: [
      { content: { parts: fns.map((f) => ({ functionCall: { name: f.name, args: f.args } })) } },
    ],
  };
}

function scripted(...responses: GeminiResponse[]) {
  let i = 0;
  const sent: unknown[] = [];
  return {
    sent,
    transport: async (req: unknown) => {
      sent.push(req);
      return responses[Math.min(i++, responses.length - 1)]!;
    },
  };
}

function client(name: string, id = "cl_1") {
  return {
    status: "single",
    client: { id, name, nameLower: name.toLowerCase(), outstandingBalance: 0 },
  };
}

/** What the model was told after the tools ran. */
function toolResponses(sent: unknown[], hop: number): Array<Record<string, unknown>> {
  const req = sent[hop] as { contents: Array<{ parts: unknown[] }> };
  const turn = req.contents.at(-1) as {
    parts: Array<{ functionResponse?: { response: Record<string, unknown> } }>;
  };
  return turn.parts.map((p) => p.functionResponse!.response);
}

function draftData<K extends DraftData["kind"]>(index: number, _kind: K) {
  return createdDrafts[index]!.data as Extract<DraftData, { kind: K }>;
}

function draftLines(index: number): Array<{ label: string; value: string }> {
  return createdDrafts[index]!.lines as Array<{ label: string; value: string }>;
}

const base = { ctx: CTX, systemPrompt: "sys", history: [] };

beforeEach(() => {
  createdDrafts.length = 0;
  resolveClientMock.mockReset();
  for (const key of Object.keys(collectionDocs)) {
    delete collectionDocs[key];
  }
});

describe("scenario: the meeting from the original brief", () => {
  it("captures who, when, why — and lands on 11 AM", async () => {
    resolveClientMock.mockResolvedValue(client("Rohan Traders"));
    const s = scripted(
      calls({
        name: "create_meeting",
        args: {
          client_name: "rohan",
          when_phrase: "kal 11 baje",
          when_tense: "future",
          day_period: "morning",
          agenda: "new labels",
        },
      }),
      say("Kal 11 baje Rohan Traders ke saath meeting — new labels ke regarding. Confirm kar dijiye."),
    );

    const res = await runAgentTurn({
      ...base,
      userText: "kal mera meeting hai 11 baje rohan ke sath new labels ke regarding to wo meeting set karde",
      transport: s.transport,
    });

    expect(res.drafts).toHaveLength(1);
    const data = draftData(0, "meeting");
    expect(data.whenLabel).toBe("Ravivar, 24 August, 11:00 AM");
    expect(data.client?.name).toBe("Rohan Traders");
    expect(data.agenda).toBe("new labels");
    // A meeting brings its own nudge without being asked.
    expect(data.reminderLeadMinutes).toBeGreaterThan(0);

    const labels = draftLines(0).map((l) => l.label);
    expect(labels).toEqual(
      expect.arrayContaining(["Client", "Kab", "Regarding", "Reminder"]),
    );

    // The model must not be told this is saved.
    expect(toolResponses(s.sent, 1)[0]!.saved).toBe(false);
  });
});

describe("scenario: quotation diya → kisko diya", () => {
  it("records the quotation as a draft", async () => {
    resolveClientMock.mockResolvedValue(client("Rohan Traders"));
    const s = scripted(
      calls({
        name: "record_quotation",
        args: { client_name: "rohan", amount: 50000 },
      }),
      say("Rohan Traders ko ₹50,000 ka quotation — confirm kar dijiye."),
    );

    const res = await runAgentTurn({
      ...base,
      userText: "rohan ko 50000 ka quotation diya",
      transport: s.transport,
    });

    expect(res.drafts).toHaveLength(1);
    expect(draftData(0, "quotation").amount).toBe(50000);
    expect(draftLines(0).find((l) => l.label === "Amount")?.value).toBe("₹50,000");
  });

  it("answers the follow-up question WITHOUT recording anything", async () => {
    resolveClientMock.mockResolvedValue(client("Rohan Traders"));
    setDocs("quotations", [
      {
        id: "q1",
        data: () => ({
          clientName: "Rohan Traders",
          amount: 50000,
          status: "pending",
          createdAtMs: Date.parse("2025-08-23T12:00:00+05:30"),
        }),
      },
    ]);

    const s = scripted(
      calls({ name: "find_records", args: { type: "quotation", window: "this_week" } }),
      say("Is hafte Rohan Traders ko ₹50,000 ka ek quotation diya tha."),
    );

    const res = await runAgentTurn({
      ...base,
      userText: "kisko quotation diya?",
      transport: s.transport,
    });

    // The whole point: a question must not create a record.
    expect(res.drafts).toHaveLength(0);
    expect(createdDrafts).toHaveLength(0);

    const data = toolResponses(s.sent, 1)[0]!.data as {
      count: number;
      clients: string[];
      totalAmount: number;
    };
    expect(data.count).toBe(1);
    expect(data.clients).toEqual(["Rohan Traders"]);
    expect(data.totalAmount).toBe(50000);
    expect(res.reply).toContain("Rohan Traders");
  });
});

describe("scenario: two things in one sentence", () => {
  it("produces two cards from one message", async () => {
    resolveClientMock.mockResolvedValue(client("Rohan Traders"));
    const s = scripted(
      calls(
        { name: "record_quotation", args: { client_name: "rohan", amount: 50000 } },
        {
          name: "create_meeting",
          args: { client_name: "rohan", when_phrase: "kal 11 baje", day_period: "morning" },
        },
      ),
      say("Dono taiyaar hain — dekh lijiye."),
    );

    const res = await runAgentTurn({
      ...base,
      userText: "rohan ko 50000 ka quotation diya, aur kal 11 baje uske saath meeting bhi hai",
      transport: s.transport,
    });

    expect(res.drafts).toHaveLength(2);
    expect(createdDrafts.map((d) => d.kind)).toEqual(["quotation", "meeting"]);
    expect(draftData(1, "meeting").whenLabel).toContain("11:00 AM");
  });
});

describe("scenario: payment aaya, past tense", () => {
  it("settles against the matching due and dates it yesterday", async () => {
    resolveClientMock.mockResolvedValue(client("Karan"));
    setDocs("payments", [
      {
        id: "p1",
        data: () => ({
          type: "payment_due",
          subType: "payment_due",
          status: "pending",
          clientId: "cl_1",
          clientName: "Karan",
          paymentVersion: 2,
          originalAmount: 30000,
          paidAmount: 0,
          remainingAmount: 30000,
          dueDateMs: Date.parse("2025-08-20T00:00:00+05:30"),
        }),
      },
    ]);

    const s = scripted(
      calls({
        name: "record_payment_received",
        args: {
          client_name: "karan",
          amount: 30000,
          when_phrase: "kal",
          when_tense: "past",
        },
      }),
      say("Karan se ₹30,000 — kal wale due par lag jaayega. Confirm?"),
    );

    const res = await runAgentTurn({ ...base, userText: "kal karan se 30000 payment aaya tha", transport: s.transport });

    expect(res.drafts).toHaveLength(1);
    const data = draftData(0, "payment_received");
    // "kal" in the past tense is yesterday, not tomorrow.
    expect(data.receivedLabel).toContain("22 August");
    expect(data.targets).toHaveLength(1);
    expect(data.targets[0]!.paymentId).toBe("p1");
  });
});

describe("scenario: aaj kisko call karna hai", () => {
  it("reads today's agenda and records nothing", async () => {
    setDocs("reminders", [
      {
        id: "r1",
        data: () => ({
          title: "Rohan ko call",
          clientName: "Rohan Traders",
          type: "call",
          subType: "call",
          status: "pending",
          scheduledTimeMs: Date.parse("2025-08-23T16:00:00+05:30"),
        }),
      },
      {
        id: "r2",
        data: () => ({
          title: "Kal wala kaam",
          type: "task",
          subType: "task",
          status: "pending",
          scheduledTimeMs: Date.parse("2025-08-25T10:00:00+05:30"),
        }),
      },
    ]);

    const s = scripted(
      calls({ name: "get_agenda", args: { window: "today" } }),
      say("Aaj sirf Rohan Traders ko call karna hai, 4 baje."),
    );

    const res = await runAgentTurn({ ...base, userText: "aaj kisko call karna hai?", transport: s.transport });

    expect(res.drafts).toHaveLength(0);
    const data = toolResponses(s.sent, 1)[0]!.data as {
      count: number;
      items: Array<{ title: string; when: string }>;
    };
    // Tomorrow's row must not leak into today's answer.
    expect(data.count).toBe(1);
    expect(data.items[0]!.when).toBe("aaj 4:00 PM");
  });
});

describe("scenario: koi important cheez hai kya", () => {
  it("returns overdue work, today's work and overdue money together", async () => {
    setDocs("reminders", [
      {
        id: "old",
        data: () => ({
          title: "Purana follow-up",
          type: "followup",
          subType: "followup",
          status: "pending",
          scheduledTimeMs: Date.parse("2025-08-19T10:00:00+05:30"),
        }),
      },
    ]);
    setDocs("payments", [
      {
        id: "due1",
        data: () => ({
          type: "payment_due",
          subType: "payment_due",
          status: "pending",
          clientId: "cl_9",
          clientName: "Late Client",
          paymentVersion: 2,
          originalAmount: 15000,
          paidAmount: 0,
          remainingAmount: 15000,
          dueDateMs: Date.parse("2025-08-10T00:00:00+05:30"),
        }),
      },
    ]);

    const s = scripted(
      calls({ name: "get_important", args: {} }),
      say("Ek purana follow-up pada hai aur Late Client ka ₹15,000 overdue hai."),
    );

    const res = await runAgentTurn({ ...base, userText: "koi important cheez hai kya?", transport: s.transport });

    expect(res.drafts).toHaveLength(0);
    const data = toolResponses(s.sent, 1)[0]!.data as {
      overdueTasks: { count: number };
      overduePayments: { count: number; totalAmount: number };
    };
    expect(data.overdueTasks.count).toBe(1);
    expect(data.overduePayments.count).toBe(1);
    expect(data.overduePayments.totalAmount).toBe(15000);
  });
});

describe("scenario: just chatting", () => {
  it("talks back without reaching for a single tool", async () => {
    const s = scripted(say("Arre, bore ho rahe ho? Batao, din kaisa gaya?"));
    const res = await runAgentTurn({
      ...base,
      userText: "aivy yaar main bore ho raha hu",
      transport: s.transport,
    });

    expect(res.trace).toHaveLength(0);
    expect(createdDrafts).toHaveLength(0);
    expect(res.reply).toContain("bore");
  });
});

describe("scenario: a general question", () => {
  it("searches the web and answers from what it found", async () => {
    const s = scripted(
      calls({ name: "web_search", args: { query: "GST rate on printing services" } }),
      say("Printing services par GST 12% hai — pehla result yahi kehta hai."),
    );

    const res = await runAgentTurn({
      ...base,
      userText: "printing services pe GST kitna lagta hai?",
      transport: s.transport,
    });

    expect(res.drafts).toHaveLength(0);
    const data = toolResponses(s.sent, 1)[0]!.data as { results: unknown[] };
    expect(data.results).toHaveLength(1);
    expect(res.reply).toContain("GST");
  });
});

describe("scenario: an ambiguous client", () => {
  it("asks instead of picking one, and writes nothing", async () => {
    resolveClientMock.mockResolvedValue({
      status: "ambiguous",
      candidates: [
        { id: "a", name: "Rohan Traders", nameLower: "rohan traders", outstandingBalance: 0 },
        { id: "b", name: "Rohan Prints", nameLower: "rohan prints", outstandingBalance: 0 },
      ],
    });

    const s = scripted(
      calls({ name: "record_quotation", args: { client_name: "rohan", amount: 50000 } }),
      say("Do Rohan hain — Traders ya Prints?"),
    );

    const res = await runAgentTurn({ ...base, userText: "rohan ko 50000 ka quotation diya", transport: s.transport });

    expect(createdDrafts).toHaveLength(0);
    expect(res.drafts).toHaveLength(0);
    const response = toolResponses(s.sent, 1)[0]!;
    expect(response.ok).toBe(false);
    expect(response.reason).toBe("needs_client_choice");
    expect(response.options).toHaveLength(2);
  });
});

describe("scenario: a detail is missing", () => {
  it("asks for the amount rather than saving a guess", async () => {
    resolveClientMock.mockResolvedValue(client("Rohan Traders"));
    const s = scripted(
      calls({ name: "record_quotation", args: { client_name: "rohan" } }),
      say("Kitne ka quotation tha?"),
    );

    const res = await runAgentTurn({ ...base, userText: "rohan ko quotation diya", transport: s.transport });

    expect(createdDrafts).toHaveLength(0);
    expect(toolResponses(s.sent, 1)[0]!.reason).toBe("needs_amount");
    expect(res.reply).toContain("Kitne");
  });
});

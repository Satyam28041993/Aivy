import { beforeEach, describe, expect, it, vi } from "vitest";

import type { AgentDraft, DraftData } from "../draftTypes";
import type { ToolContext } from "../toolTypes";

// Firestore and the draft collection are stubbed: these tests are about what a
// tool *decides* — which client, which instant, which card lines — not about
// persistence, which `commit.ts` owns.
const createDraftMock = vi.fn();
const resolveClientMock = vi.fn();
const openDuesMock = vi.fn();

vi.mock("../draftStore", () => ({
  createDraft: (input: Record<string, unknown>) => {
    createDraftMock(input);
    return Promise.resolve({
      id: "draft_1",
      status: "pending",
      createdAtMs: 0,
      committedAtMs: null,
      resultIds: [],
      ...input,
    } as unknown as AgentDraft);
  },
  listPendingDrafts: () => Promise.resolve([]),
  markDraftStatus: () => Promise.resolve(),
}));

vi.mock("../clientResolve", async () => {
  const actual = await vi.importActual<typeof import("../clientResolve")>("../clientResolve");
  return {
    ...actual,
    resolveClient: (...args: unknown[]) => resolveClientMock(...args),
  };
});

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: () => ({
      doc: () => ({
        collection: () => ({
          get: () => Promise.resolve({ docs: openDuesMock() }),
        }),
      }),
    }),
  }),
  FieldValue: { serverTimestamp: () => "ts" },
}));

const {
  createMeetingTool,
  createReminderTool,
  recordOrderTool,
  recordPaymentDueTool,
  recordPaymentReceivedTool,
  recordQuotationTool,
  rememberFactTool,
  formatInr,
} = await import("./writeTools");

const CTX: ToolContext = {
  uid: "u1",
  timezone: "Asia/Kolkata",
  // Saturday 23 August 2025, 14:30 IST.
  nowIso: "2025-08-23T14:30:00+05:30",
  chatId: "c1",
};

function lastDraft(): { data: DraftData; lines: Array<{ label: string; value: string }>; title: string } {
  const call = createDraftMock.mock.calls.at(-1)![0];
  return call as never;
}

function single(name = "Rohan Traders", id = "cl_1") {
  return { status: "single", client: { id, name, nameLower: name.toLowerCase(), outstandingBalance: 0 } };
}

beforeEach(() => {
  createDraftMock.mockClear();
  resolveClientMock.mockReset();
  openDuesMock.mockReset();
  openDuesMock.mockReturnValue([]);
});

describe("formatInr", () => {
  it("uses Indian grouping", () => {
    expect(formatInr(50000)).toBe("₹50,000");
    expect(formatInr(120000)).toBe("₹1,20,000");
  });
});

describe("create_meeting", () => {
  it("resolves the user's own example correctly", async () => {
    resolveClientMock.mockResolvedValue(single("Rohan Traders"));
    const res = await createMeetingTool(CTX, {
      client_name: "rohan",
      when_phrase: "kal 11 baje",
      when_tense: "future",
      day_period: "morning",
      agenda: "new labels",
    });

    expect(res.ok).toBe(true);
    const d = lastDraft();
    expect(d.data.kind).toBe("meeting");
    const data = d.data as Extract<DraftData, { kind: "meeting" }>;
    // 11 AM, not 11 PM.
    expect(data.whenLabel).toBe("Sunday, 24 August, 11:00 AM");
    expect(data.agenda).toBe("new labels");
    expect(data.client?.name).toBe("Rohan Traders");
    expect(data.reminderLeadMinutes).toBe(15);

    const labels = d.lines.map((l) => l.label);
    expect(labels).toContain("Client");
    expect(labels).toContain("When");
    expect(labels).toContain("Regarding");
    expect(labels).toContain("Reminder");
  });

  it("asks for the date instead of guessing", async () => {
    const res = await createMeetingTool(CTX, { client_name: "rohan" });
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.reason).toBe("needs_date");
    expect(createDraftMock).not.toHaveBeenCalled();
  });

  it("asks which client when the name is ambiguous", async () => {
    resolveClientMock.mockResolvedValue({
      status: "ambiguous",
      candidates: [
        { id: "a", name: "Rohan Traders", nameLower: "rohan traders", outstandingBalance: 0 },
        { id: "b", name: "Rohan Prints", nameLower: "rohan prints", outstandingBalance: 0 },
      ],
    });
    const res = await createMeetingTool(CTX, {
      client_name: "rohan",
      when_phrase: "kal 11 baje",
    });
    expect(res.ok).toBe(false);
    if (!res.ok) {
      expect(res.reason).toBe("needs_client_choice");
      expect(res.options).toHaveLength(2);
    }
    expect(createDraftMock).not.toHaveBeenCalled();
  });

  it("marks an unknown client as one to create", async () => {
    resolveClientMock.mockResolvedValue({ status: "not_found", query: "naya client" });
    const res = await createMeetingTool(CTX, {
      client_name: "naya client",
      when_phrase: "kal 11 baje",
    });
    expect(res.ok).toBe(true);
    const data = lastDraft().data as Extract<DraftData, { kind: "meeting" }>;
    expect(data.client?.createNew).toBe(true);
    expect(data.client?.id).toBeNull();
  });

  it("works without any client at all", async () => {
    const res = await createMeetingTool(CTX, { when_phrase: "kal 11 baje" });
    expect(res.ok).toBe(true);
    const data = lastDraft().data as Extract<DraftData, { kind: "meeting" }>;
    expect(data.client).toBeNull();
  });
});

describe("create_reminder", () => {
  it("builds a call reminder with the resolved time", async () => {
    resolveClientMock.mockResolvedValue(single("Karan"));
    const res = await createReminderTool(CTX, {
      title: "Karan ko call karna hai",
      when_phrase: "kal 4 baje",
      client_name: "karan",
      reminder_type: "call",
    });
    expect(res.ok).toBe(true);
    const d = lastDraft();
    const data = d.data as Extract<DraftData, { kind: "reminder" }>;
    expect(data.reminderType).toBe("call");
    expect(data.whenLabel).toContain("4:00 PM");
    expect(d.title).toBe("Call reminder");
  });

  it("falls back to a task type for unknown values", async () => {
    const res = await createReminderTool(CTX, {
      title: "kuch bhi",
      when_phrase: "kal",
      reminder_type: "banana",
    });
    expect(res.ok).toBe(true);
    const data = lastDraft().data as Extract<DraftData, { kind: "reminder" }>;
    expect(data.reminderType).toBe("task");
    expect(data.priority).toBe("medium");
  });

  it("needs a title", async () => {
    const res = await createReminderTool(CTX, { when_phrase: "kal" });
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.reason).toBe("needs_detail");
  });
});

describe("record_quotation", () => {
  it("records the amount and defaults the follow-up a week out", async () => {
    resolveClientMock.mockResolvedValue(single("Rohan Traders"));
    const res = await recordQuotationTool(CTX, {
      client_name: "rohan",
      amount: 50000,
    });
    expect(res.ok).toBe(true);
    const d = lastDraft();
    const data = d.data as Extract<DraftData, { kind: "quotation" }>;
    expect(data.amount).toBe(50000);
    expect(data.client.name).toBe("Rohan Traders");
    // 23 Aug + 7 days.
    expect(data.followUpLabel).toContain("30 August");
    expect(d.lines.find((l) => l.label === "Amount")?.value).toBe("₹50,000");
  });

  it("accepts a written amount", async () => {
    resolveClientMock.mockResolvedValue(single());
    const res = await recordQuotationTool(CTX, {
      client_name: "rohan",
      amount: "₹1,20,000",
    });
    expect(res.ok).toBe(true);
    const data = lastDraft().data as Extract<DraftData, { kind: "quotation" }>;
    expect(data.amount).toBe(120000);
  });

  it("asks for the amount rather than saving a zero", async () => {
    resolveClientMock.mockResolvedValue(single());
    const res = await recordQuotationTool(CTX, { client_name: "rohan" });
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.reason).toBe("needs_amount");
  });

  it("rejects a command word in the client slot", async () => {
    const res = await recordQuotationTool(CTX, { client_name: "cancel", amount: 100 });
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.reason).toBe("needs_detail");
  });
});

describe("record_order", () => {
  it("builds an order draft", async () => {
    resolveClientMock.mockResolvedValue(single("Karan Enterprises"));
    const res = await recordOrderTool(CTX, { client_name: "karan", amount: 75000 });
    expect(res.ok).toBe(true);
    const data = lastDraft().data as Extract<DraftData, { kind: "order" }>;
    expect(data.amount).toBe(75000);
    expect(data.client.name).toBe("Karan Enterprises");
  });
});

describe("record_payment_due", () => {
  it("defaults the due date 30 days out", async () => {
    resolveClientMock.mockResolvedValue(single());
    const res = await recordPaymentDueTool(CTX, { client_name: "rohan", amount: 40000 });
    expect(res.ok).toBe(true);
    const data = lastDraft().data as Extract<DraftData, { kind: "payment_due" }>;
    expect(data.amount).toBe(40000);
    expect(data.dueLabel).toContain("22 September");
  });

  it("honours a stated due date", async () => {
    resolveClientMock.mockResolvedValue(single());
    const res = await recordPaymentDueTool(CTX, {
      client_name: "rohan",
      amount: 40000,
      due_phrase: "15 tarikh",
    });
    expect(res.ok).toBe(true);
    const data = lastDraft().data as Extract<DraftData, { kind: "payment_due" }>;
    expect(data.dueLabel).toContain("15 September");
  });
});

describe("record_payment_received", () => {
  function dueDoc(id: string, remaining: number, dueMs: number | null, clientId = "cl_1") {
    return {
      id,
      data: () => ({
        type: "payment_due",
        subType: "payment_due",
        status: "pending",
        clientId,
        clientName: "Rohan Traders",
        paymentVersion: 2,
        originalAmount: remaining,
        paidAmount: 0,
        remainingAmount: remaining,
        ...(dueMs ? { dueDateMs: dueMs } : {}),
      }),
    };
  }

  it("targets the exact-amount due when there is one", async () => {
    resolveClientMock.mockResolvedValue(single());
    openDuesMock.mockReturnValue([
      dueDoc("p1", 30000, Date.UTC(2025, 7, 10)),
      dueDoc("p2", 50000, Date.UTC(2025, 7, 20)),
    ]);
    const res = await recordPaymentReceivedTool(CTX, {
      client_name: "rohan",
      amount: 30000,
    });
    expect(res.ok).toBe(true);
    const data = lastDraft().data as Extract<DraftData, { kind: "payment_received" }>;
    expect(data.targets).toHaveLength(1);
    expect(data.targets[0]!.paymentId).toBe("p1");
  });

  it("keeps every due when no single one matches, oldest first", async () => {
    resolveClientMock.mockResolvedValue(single());
    openDuesMock.mockReturnValue([
      dueDoc("newer", 20000, Date.UTC(2025, 7, 20)),
      dueDoc("older", 20000, Date.UTC(2025, 7, 10)),
    ]);
    const res = await recordPaymentReceivedTool(CTX, {
      client_name: "rohan",
      amount: 35000,
    });
    expect(res.ok).toBe(true);
    const data = lastDraft().data as Extract<DraftData, { kind: "payment_received" }>;
    expect(data.targets.map((t) => t.paymentId)).toEqual(["older", "newer"]);
  });

  it("records a standalone receipt when the client has no open due", async () => {
    // Money arriving against no recorded due is still money arriving. Refusing
    // would lose the fact; the card says plainly that nothing was settled.
    resolveClientMock.mockResolvedValue(single());
    openDuesMock.mockReturnValue([]);
    const res = await recordPaymentReceivedTool(CTX, {
      client_name: "rohan",
      amount: 1000,
    });
    expect(res.ok).toBe(true);
    const draft = lastDraft();
    const data = draft.data as Extract<DraftData, { kind: "payment_received" }>;
    expect(data.targets).toEqual([]);
    expect(JSON.stringify(draft.lines)).toContain("No open due");
  });

  it("does not offer to create an unknown client", async () => {
    resolveClientMock.mockResolvedValue({ status: "not_found", query: "kaun" });
    const res = await recordPaymentReceivedTool(CTX, {
      client_name: "kaun",
      amount: 1000,
    });
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.reason).toBe("client_not_found");
  });

  it("reads the receipt date in the past tense by default", async () => {
    resolveClientMock.mockResolvedValue(single());
    openDuesMock.mockReturnValue([dueDoc("p1", 5000, null)]);
    // "kal payment aaya tha" — kal must mean yesterday here.
    const res = await recordPaymentReceivedTool(CTX, {
      client_name: "rohan",
      amount: 5000,
      when_phrase: "kal",
    });
    expect(res.ok).toBe(true);
    const data = lastDraft().data as Extract<DraftData, { kind: "payment_received" }>;
    expect(data.receivedLabel).toContain("22 August");
  });
});

describe("remember_fact", () => {
  it("stores the fact under a category", async () => {
    const res = await rememberFactTool(CTX, {
      category: "preference",
      fact: "Sir ko subah 9 baje se pehle call pasand nahi",
    });
    expect(res.ok).toBe(true);
    const data = lastDraft().data as Extract<DraftData, { kind: "remember_fact" }>;
    expect(data.category).toBe("preference");
    expect(data.fact).toContain("subah 9 baje");
  });

  it("needs something to remember", async () => {
    const res = await rememberFactTool(CTX, { category: "x" });
    expect(res.ok).toBe(false);
  });

  it("keeps a batch of details apart instead of collapsing them into one", async () => {
    const res = await rememberFactTool(CTX, {
      facts: [
        { key: "wife", value: "Ruchi Singh, born 19 Oct 1995" },
        { key: "daughter", value: "Prisha Singh, born 16 Sep 2020" },
        { key: "Wedding Anniversary", value: "21 May 2017" },
      ],
    });
    expect(res.ok).toBe(true);

    const draft = lastDraft();
    const data = draft.data as Extract<DraftData, { kind: "remember_fact" }>;
    expect(data.facts?.map((f) => f.key)).toEqual([
      "wife",
      "daughter",
      // Spaces and casing are normalised, so the same subject always lands on
      // the same key however it was written.
      "wedding_anniversary",
    ]);
    // Every fact is on the card, so a wrong date can be caught before it sticks.
    expect(draft.lines).toHaveLength(3);
    expect(draft.title).toBe("Remember 3 things");
  });

  it("drops a repeated key rather than writing the same subject twice", async () => {
    await rememberFactTool(CTX, {
      facts: [
        { key: "city", value: "Vasai East" },
        { key: "City", value: "Palghar" },
      ],
    });
    const data = lastDraft().data as Extract<DraftData, { kind: "remember_fact" }>;
    expect(data.facts).toEqual([{ key: "city", value: "Vasai East" }]);
  });

  it("still takes a single fact the old way", async () => {
    await rememberFactTool(CTX, { category: "city", fact: "Vasai East" });
    const data = lastDraft().data as Extract<DraftData, { kind: "remember_fact" }>;
    expect(data.category).toBe("city");
    expect(data.fact).toBe("Vasai East");
    expect(data.facts).toEqual([{ key: "city", value: "Vasai East" }]);
  });
});

describe("repeating reminders", () => {
  it("marks a 'every month' ask as the single reminder it actually is", async () => {
    const res = await createReminderTool(CTX, {
      title: "GST filing",
      when_phrase: "har mahine 5 tarikh ko",
    });
    expect(res.ok).toBe(true);
    expect(JSON.stringify(lastDraft().lines)).toContain("One-time only");
    expect(res.ok && res.kind === "draft" && res.hint).toContain("not a repeating one");
  });

  it("leaves an ordinary reminder unmarked", async () => {
    const res = await createReminderTool(CTX, {
      title: "call Rohan",
      when_phrase: "kal 5 baje",
    });
    expect(res.ok).toBe(true);
    expect(JSON.stringify(lastDraft().lines)).not.toContain("One-time only");
  });
});

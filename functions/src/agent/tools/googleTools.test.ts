import { beforeEach, describe, expect, it, vi } from "vitest";

import type { AgentDraft, DraftData } from "../draftTypes";
import type { ToolContext } from "../toolTypes";

// Same shape as writeTools.test.ts: the draft store and Google itself are
// stubbed, because what matters here is what the tool *decides* — whether it
// asks for something, what the card says, and what commit will replay.
const createDraftMock = vi.fn();
const peopleSearchMock = vi.fn();
const calendarListMock = vi.fn();
const gmailListMock = vi.fn();
const prefsMock = vi.fn();

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
}));

vi.mock("../google/workspace", async () => {
  const actual = await vi.importActual<typeof import("../google/workspace")>("../google/workspace");
  return {
    ...actual,
    peopleSearch: (...a: unknown[]) => peopleSearchMock(...a),
    calendarListEvents: (...a: unknown[]) => calendarListMock(...a),
    gmailListRecent: (...a: unknown[]) => gmailListMock(...a),
  };
});

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: () => ({
      doc: () => ({
        collection: () => ({
          doc: () => ({ get: () => Promise.resolve({ data: () => prefsMock() }) }),
        }),
      }),
    }),
  }),
}));

const {
  appendSheetRowTool,
  createCalendarEventTool,
  findContactTool,
  listCalendarEventsTool,
  listRecentEmailsTool,
  sendEmailTool,
} = await import("./googleTools");
const { GoogleApiError } = await import("../google/workspace");

const CTX: ToolContext = {
  uid: "u1",
  timezone: "Asia/Kolkata",
  // Saturday 23 August 2025, 14:30 IST.
  nowIso: "2025-08-23T14:30:00+05:30",
  chatId: "c1",
  googleToken: "tok",
};

const NO_GOOGLE: ToolContext = { ...CTX, googleToken: null };

function lastDraft(): { data: DraftData; lines: Array<{ label: string; value: string }> } {
  return createDraftMock.mock.calls.at(-1)![0];
}

beforeEach(() => {
  createDraftMock.mockReset();
  peopleSearchMock.mockReset();
  calendarListMock.mockReset();
  gmailListMock.mockReset();
  prefsMock.mockReset().mockReturnValue({});
});

describe("without a Google token", () => {
  it("every Google tool says so instead of failing silently", async () => {
    const results = await Promise.all([
      createCalendarEventTool(NO_GOOGLE, { summary: "x", when_phrase: "kal 11 baje" }),
      sendEmailTool(NO_GOOGLE, { to: "a@b.com", body: "hi" }),
      appendSheetRowTool(NO_GOOGLE, { cells: ["a"] }),
      listCalendarEventsTool(NO_GOOGLE, {}),
      listRecentEmailsTool(NO_GOOGLE, {}),
      findContactTool(NO_GOOGLE, { query: "rohan" }),
    ]);
    for (const r of results) {
      expect(r.ok).toBe(false);
      expect(r.ok === false && r.message).toContain("Allow Google extras");
    }
    expect(createDraftMock).not.toHaveBeenCalled();
  });
});

describe("create_calendar_event", () => {
  it("resolves the phrase on the server and drafts rather than writing", async () => {
    const res = await createCalendarEventTool(CTX, {
      summary: "Dentist",
      when_phrase: "kal 11 baje",
      day_period: "morning",
      duration_minutes: 30,
    });
    expect(res.ok).toBe(true);
    expect(res.ok && res.kind).toBe("draft");

    const d = lastDraft().data as Extract<DraftData, { kind: "calendar_event" }>;
    expect(d.kind).toBe("calendar_event");
    expect(d.durationMinutes).toBe(30);
    // 24 August 2025, 11:00 IST — morning, not 23:00.
    expect(new Date(d.whenMs).toISOString()).toBe("2025-08-24T05:30:00.000Z");
  });

  it("asks for a date instead of inventing one", async () => {
    const res = await createCalendarEventTool(CTX, { summary: "Dentist" });
    expect(res.ok === false && res.reason).toBe("needs_date");
  });
});

describe("send_email", () => {
  it("takes an address as given", async () => {
    const res = await sendEmailTool(CTX, {
      to: "rohan@example.com",
      subject: "Quotation",
      body: "Namaste",
    });
    expect(res.ok).toBe(true);
    expect(peopleSearchMock).not.toHaveBeenCalled();
    const d = lastDraft().data as Extract<DraftData, { kind: "email" }>;
    expect(d.to).toBe("rohan@example.com");
  });

  it("looks a bare name up in contacts", async () => {
    peopleSearchMock.mockResolvedValue([
      { name: "Rohan Traders", emails: ["rohan@example.com"], phones: [] },
    ]);
    const res = await sendEmailTool(CTX, { to: "rohan", body: "Namaste" });
    expect(res.ok).toBe(true);
    const d = lastDraft().data as Extract<DraftData, { kind: "email" }>;
    expect(d.to).toBe("rohan@example.com");
    expect(d.toName).toBe("Rohan Traders");
    expect(lastDraft().lines[0]!.value).toBe("Rohan Traders <rohan@example.com>");
  });

  it("puts the choice back to the user when two contacts match", async () => {
    peopleSearchMock.mockResolvedValue([
      { name: "Rohan Traders", emails: ["rohan@a.com"], phones: [] },
      { name: "Rohan Kumar", emails: ["rohan@b.com"], phones: [] },
    ]);
    const res = await sendEmailTool(CTX, { to: "rohan", body: "hi" });
    expect(res.ok === false && res.reason).toBe("needs_client_choice");
    expect(res.ok === false && res.options).toHaveLength(2);
    expect(createDraftMock).not.toHaveBeenCalled();
  });

  it("asks for the address rather than guessing when nothing matches", async () => {
    peopleSearchMock.mockResolvedValue([]);
    const res = await sendEmailTool(CTX, { to: "rohan", body: "hi" });
    expect(res.ok === false && res.reason).toBe("client_not_found");
  });

  it("turns a Google permission error into a plain sentence", async () => {
    peopleSearchMock.mockRejectedValue(new GoogleApiError("People", 403, "scope"));
    const res = await sendEmailTool(CTX, { to: "rohan", body: "hi" });
    expect(res.ok === false && res.message).toContain("Allow Google extras");
  });
});

describe("append_sheet_row", () => {
  it("uses the saved default sheet", async () => {
    prefsMock.mockReturnValue({ defaultSpreadsheetId: "sheet123" });
    const res = await appendSheetRowTool(CTX, { cells: ["30 Aug", "Rohan"] });
    expect(res.ok).toBe(true);
    const d = lastDraft().data as Extract<DraftData, { kind: "sheet_row" }>;
    expect(d.spreadsheetId).toBe("sheet123");
    expect(d.tab).toBe("Sheet1");
  });

  it("says what to do when no default is set", async () => {
    prefsMock.mockReturnValue({});
    const res = await appendSheetRowTool(CTX, { cells: ["a"] });
    expect(res.ok === false && res.reason).toBe("needs_detail");
    expect(createDraftMock).not.toHaveBeenCalled();
  });
});

describe("reads", () => {
  it("hands calendar rows back as data, not prose", async () => {
    calendarListMock.mockResolvedValue([
      { id: "a", summary: "Meeting", startIso: "2025-08-24T05:30:00Z", endIso: "", allDay: false, location: "", link: "" },
    ]);
    const res = await listCalendarEventsTool(CTX, { window: "tomorrow" });
    expect(res.ok && res.kind).toBe("data");
    const data = res.ok && res.kind === "data" ? (res.data as Record<string, unknown>) : {};
    expect(data.count).toBe(1);

    const arg = calendarListMock.mock.calls[0]![1] as { timeMinIso: string; timeMaxIso: string };
    // Tomorrow in IST starts at 18:30Z the previous day.
    expect(arg.timeMinIso).toBe("2025-08-23T18:30:00.000Z");
  });

  it("reports an empty inbox as zero rather than a failure", async () => {
    gmailListMock.mockResolvedValue([]);
    const res = await listRecentEmailsTool(CTX, {});
    expect(res.ok).toBe(true);
  });

  it("says plainly when a contact is not found", async () => {
    peopleSearchMock.mockResolvedValue([]);
    const res = await findContactTool(CTX, { query: "zzz" });
    expect(res.ok === false && res.reason).toBe("nothing_found");
  });
});

import { beforeEach, describe, expect, it, vi } from "vitest";

import type { AgentDraft, DraftData } from "./draftTypes";

/**
 * The Google commits are the only writes in this codebase with no undo — a mail
 * is gone the moment it is sent. So these check the two things that matter:
 * nothing leaves without a token, and a Google refusal does not read as success.
 */

const insertEventMock = vi.fn();
const gmailSendMock = vi.fn();
const sheetsAppendMock = vi.fn();
const draft = { current: null as AgentDraft | null };
const markStatusMock = vi.fn();
const prefsMock = vi.fn();

vi.mock("./google/workspace", async () => {
  const actual = await vi.importActual<typeof import("./google/workspace")>("./google/workspace");
  return {
    ...actual,
    calendarInsertEvent: (...a: unknown[]) => insertEventMock(...a),
    gmailSend: (...a: unknown[]) => gmailSendMock(...a),
    sheetsAppendRow: (...a: unknown[]) => sheetsAppendMock(...a),
  };
});

vi.mock("./draftStore", () => ({
  getDraft: () => Promise.resolve(draft.current),
  markDraftStatus: (...a: unknown[]) => {
    markStatusMock(...a);
    return Promise.resolve();
  },
}));

vi.mock("./clientResolve", () => ({
  createClient: () => Promise.resolve({ id: "c1", name: "Rohan" }),
}));


vi.mock("firebase-admin/firestore", () => ({
  FieldValue: { serverTimestamp: () => "ts" },
  getFirestore: () => ({
    collection: () => ({
      doc: () => ({
        collection: () => ({
          doc: (id?: string) => ({
            id: id ?? "generated",
            get: () => Promise.resolve({ data: () => prefsMock() }),
            set: () => Promise.resolve(),
          }),
        }),
      }),
    }),
  }),
}));

const { commitDraft } = await import("./commit");
const { GoogleApiError } = await import("./google/workspace");

function pending(data: DraftData): AgentDraft {
  return {
    id: "d1",
    kind: data.kind,
    status: "pending",
    title: "t",
    icon: "x",
    lines: [],
    data,
    chatId: "c1",
    createdAtMs: 0,
    committedAtMs: null,
    resultIds: [],
  };
}

const EMAIL: DraftData = {
  kind: "email",
  to: "rohan@example.com",
  toName: "Rohan",
  subject: "Quotation",
  body: "Namaste",
};

beforeEach(() => {
  insertEventMock.mockReset().mockResolvedValue({ id: "ev1", link: "l" });
  gmailSendMock.mockReset().mockResolvedValue("m1");
  sheetsAppendMock.mockReset().mockResolvedValue(1);
  markStatusMock.mockReset();
  prefsMock.mockReset().mockReturnValue({});
});

it("sends nothing when the turn carried no Google token", async () => {
  draft.current = pending(EMAIL);
  const res = await commitDraft("u1", "d1", {});
  expect(res.ok).toBe(false);
  expect(gmailSendMock).not.toHaveBeenCalled();
  // A failed commit must leave the card pending, so it can be retried.
  expect(markStatusMock).not.toHaveBeenCalled();
});

it("sends the mail and marks the draft committed", async () => {
  draft.current = pending(EMAIL);
  const res = await commitDraft("u1", "d1", { googleToken: "tok" });
  expect(res.ok).toBe(true);
  expect(res.message).toContain("Rohan");
  expect(gmailSendMock).toHaveBeenCalledWith("tok", {
    to: "rohan@example.com",
    subject: "Quotation",
    body: "Namaste",
  });
  expect(markStatusMock).toHaveBeenCalledWith("u1", "d1", "committed", ["m1"]);
});

it("does not report success when Gmail refuses", async () => {
  draft.current = pending(EMAIL);
  gmailSendMock.mockRejectedValue(new GoogleApiError("Gmail", 403, "scope"));
  const res = await commitDraft("u1", "d1", { googleToken: "tok" });
  expect(res.ok).toBe(false);
  expect(res.message).toContain("Allow Google extras");
  expect(markStatusMock).not.toHaveBeenCalled();
});

it("falls back to the saved sheet id at commit time", async () => {
  prefsMock.mockReturnValue({ defaultSpreadsheetId: "sheet123" });
  draft.current = pending({
    kind: "sheet_row",
    spreadsheetId: null,
    tab: "Log",
    cells: ["a", "b"],
  });
  const res = await commitDraft("u1", "d1", { googleToken: "tok" });
  expect(res.ok).toBe(true);
  expect(sheetsAppendMock).toHaveBeenCalledWith("tok", {
    spreadsheetId: "sheet123",
    tab: "Log",
    cells: ["a", "b"],
  });
});

describe("meeting", () => {
  const MEETING: DraftData = {
    kind: "meeting",
    client: { id: "c1", name: "Rohan", createNew: false },
    agenda: "new labels",
    whenIso: "2025-08-30T11:00:00+05:30",
    whenMs: Date.UTC(2025, 7, 30, 5, 30),
    whenLabel: "Ravivar, 30 August, 11:00 AM",
    reminderLeadMinutes: 15,
    note: null,
    addToCalendar: true,
    durationMinutes: 45,
  };

  it("puts a confirmed meeting on the calendar too", async () => {
    draft.current = pending(MEETING);
    const res = await commitDraft("u1", "d1", { googleToken: "tok" });
    expect(res.ok).toBe(true);
    expect(res.message).toContain("Google Calendar");
    expect(insertEventMock.mock.calls[0]![1]).toMatchObject({
      summary: "Meeting: new labels",
      durationMinutes: 45,
    });
  });

  it("still saves the meeting when Calendar fails", async () => {
    draft.current = pending(MEETING);
    insertEventMock.mockRejectedValue(new GoogleApiError("Calendar", 403, "scope"));
    const res = await commitDraft("u1", "d1", { googleToken: "tok" });
    // The reminder is the record that matters; Calendar is a bonus.
    expect(res.ok).toBe(true);
    expect(res.message).toContain("Meeting set");
    expect(res.message).toContain("Google permission");
  });

  it("skips Calendar silently when Google is not connected", async () => {
    draft.current = pending(MEETING);
    const res = await commitDraft("u1", "d1", {});
    expect(res.ok).toBe(true);
    expect(res.message).not.toContain("Calendar");
    expect(insertEventMock).not.toHaveBeenCalled();
  });
});

import { describe, expect, it } from "vitest";

import { resolveDueHint } from "./dates";
import {
  detectProjectTurn,
  extractProjectNameHint,
  looksLikeProjectDump,
  looksLikeSimpleReminder,
} from "./detect";
import { heuristicExtractDraft, inferKindFromText, inferStatusFromText } from "./extract";
import { reminderPayloadForItem } from "./reminders";
import {
  bucketItems,
  formatProjectSummaryHinglish,
  formatTodayItemsHinglish,
  nextActionLine,
} from "./summary";
import type { ProjectClock, ProjectItemRecord, ProjectRecord } from "./types";

const CLOCK: ProjectClock = {
  timezone: "Asia/Kolkata",
  nowIso: "2026-08-31T10:00:00+05:30",
};

const DUMP =
  "Sharma ko 3 label sample dikhaye, glossy wala pasand aaya, rate Monday tak dena hai, unka QC head 5 tarikh ko aayega";

describe("detectProjectTurn", () => {
  it("treats a multi-item field note as a dump", () => {
    expect(looksLikeProjectDump(DUMP)).toBe(true);
    expect(detectProjectTurn(DUMP)).toBe("dump");
  });

  it("does not steal a simple reminder", () => {
    expect(looksLikeSimpleReminder("rajesh ko aaj 3 baje call karna hai")).toBe(
      true,
    );
    expect(detectProjectTurn("rajesh ko aaj 3 baje call karna hai")).toBeNull();
  });

  it("does not steal a payment line", () => {
    expect(detectProjectTurn("karan se 50000 lena hai 5 din baad")).toBeNull();
  });

  it("detects status queries", () => {
    expect(detectProjectTurn("Pune project ka kya haal hai")).toBe("query");
    expect(extractProjectNameHint("Pune project ka kya haal hai")).toBe("Pune");
    expect(detectProjectTurn("kya atka hai Sharma wale project pe")).toBe(
      "query",
    );
  });

  it("detects today and updates", () => {
    expect(detectProjectTurn("aaj ke project items kya hain")).toBe("today");
    expect(detectProjectTurn("Pune sample done ho gaya")).toBe("update");
  });
});

describe("heuristicExtractDraft", () => {
  it("splits the Sharma dump into dated waiting/meeting items", () => {
    const draft = heuristicExtractDraft(DUMP, CLOCK);
    expect(draft.flowCategoryId).toBe("project_items");
    expect(draft.items.length).toBeGreaterThanOrEqual(3);
    expect(draft.client.toLowerCase()).toContain("sharma");
    const kinds = draft.items.map((i) => i.kind);
    expect(kinds).toContain("sample");
    expect(kinds).toContain("rate");
    expect(kinds).toContain("meeting");
    const rate = draft.items.find((i) => i.kind === "rate");
    expect(rate?.status).toBe("waiting_on_them");
    expect(rate?.dueAtMs).toBeTruthy();
    const meeting = draft.items.find((i) => i.kind === "meeting");
    expect(meeting?.waitingOn.toLowerCase()).toContain("qc");
    expect(meeting?.dueAtMs).toBeTruthy();
  });

  it("infers kinds and waiting status", () => {
    expect(inferKindFromText("3 label sample dikhaye")).toBe("sample");
    expect(inferKindFromText("unka QC head aayega")).toBe("meeting");
    expect(inferStatusFromText("rate Monday tak dena hai unse")).toBe(
      "waiting_on_them",
    );
  });
});

describe("resolveDueHint", () => {
  it("resolves Monday from a Monday-week reference", () => {
    const due = resolveDueHint("Monday tak", CLOCK);
    expect(due).not.toBeNull();
    const d = new Date(due!.ms);
    expect(d.getUTCDay()).toBe(1); // Monday
  });

  it("resolves 5 tarikh in the current or next month", () => {
    const due = resolveDueHint("5 tarikh", CLOCK);
    expect(due).not.toBeNull();
    const d = new Date(due!.ms);
    expect(d.getUTCDate() === 5 || d.getDate() === 5).toBe(true);
  });

  it("keeps an explicit 4pm instead of default 11", () => {
    const due = resolveDueHint("kal 4pm", CLOCK);
    expect(due).not.toBeNull();
    const d = new Date(due!.iso);
    expect(d.getHours() === 16 || due!.iso.includes("T16:")).toBe(true);
  });
});

describe("summary + reminders", () => {
  const project: ProjectRecord = {
    id: "p1",
    name: "Pune",
    nameKey: "pune",
    client: "Sharma",
    clientKey: "sharma",
    status: "active",
    notes: "",
    createdAtMs: 1,
    updatedAtMs: 1,
  };

  const items: ProjectItemRecord[] = [
    {
      id: "i1",
      projectId: "p1",
      projectName: "Pune",
      title: "Rate dena",
      description: "rate Monday tak",
      kind: "rate",
      status: "waiting_on_them",
      dueAtIso: "2026-09-07T11:00:00+05:30",
      dueAtMs: Date.parse("2026-09-07T11:00:00+05:30"),
      waitingOn: "Sharma",
      notes: "",
      reminderId: null,
      createdAtMs: 1,
      updatedAtMs: 1,
    },
    {
      id: "i2",
      projectId: "p1",
      projectName: "Pune",
      title: "QC visit",
      description: "QC head aayega",
      kind: "meeting",
      status: "pending",
      dueAtIso: null,
      dueAtMs: null,
      waitingOn: "QC head",
      notes: "",
      reminderId: null,
      createdAtMs: 1,
      updatedAtMs: 1,
    },
    {
      id: "i3",
      projectId: "p1",
      projectName: "Pune",
      title: "Sample glossy",
      description: "dikhaya",
      kind: "sample",
      status: "done",
      dueAtIso: null,
      dueAtMs: null,
      waitingOn: "",
      notes: "",
      reminderId: null,
      createdAtMs: 1,
      updatedAtMs: 1,
    },
  ];

  it("buckets waiting_on_them separately from pending", () => {
    const b = bucketItems(items);
    expect(b.waitingOnThem).toHaveLength(1);
    expect(b.pending).toHaveLength(1);
    expect(b.done).toHaveLength(1);
  });

  it("summarises in Hinglish with next action on the client", () => {
    const text = formatProjectSummaryHinglish(project, items);
    expect(text.toLowerCase()).toContain("waiting on them");
    expect(text).toContain("Pune");
    expect(nextActionLine(items).toLowerCase()).toContain("sharma");
  });

  it("formats an empty today list", () => {
    expect(formatTodayItemsHinglish([])).toMatch(/Aaj koi project item/i);
  });

  it("maps dated items onto the existing reminder shape", () => {
    const rem = reminderPayloadForItem(items[0]!, "Pune", "Sharma");
    expect(rem).not.toBeNull();
    expect(rem!.isFollowUp).toBe(true);
    expect(rem!.subType).toBe("project_item");
    expect(rem!.title).toMatch(/Pune/);
    expect(reminderPayloadForItem(items[1]!, "Pune", "Sharma")).toBeNull();
  });
});

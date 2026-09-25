import { beforeEach, describe, expect, it, vi } from "vitest";

import type { AgentDraft, DraftData } from "../draftTypes";
import type { ToolContext } from "../toolTypes";

const createDraftMock = vi.fn();
const findByPhoneMock = vi.fn();
const findLibraryMock = vi.fn();
const searchLibraryMock = vi.fn();

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

vi.mock("../contactStore", async () => {
  const actual = await vi.importActual<typeof import("../contactStore")>("../contactStore");
  return {
    ...actual,
    findContactByPhone: (...a: unknown[]) => findByPhoneMock(...a),
  };
});

vi.mock("../libraryStore", async () => {
  const actual = await vi.importActual<typeof import("../libraryStore")>("../libraryStore");
  return {
    ...actual,
    findLibraryByTitleKind: (...a: unknown[]) => findLibraryMock(...a),
    searchLibrary: (...a: unknown[]) => searchLibraryMock(...a),
  };
});

const { saveContactTool, saveLibraryItemTool, searchLibraryTool } = await import("./libraryTools");

const CTX: ToolContext = {
  uid: "u1",
  timezone: "Asia/Kolkata",
  nowIso: "2025-08-23T14:30:00+05:30",
  chatId: "c1",
};

function lastDraft(): { data: DraftData; lines: Array<{ label: string; value: string }>; title: string } {
  return createDraftMock.mock.calls.at(-1)![0] as never;
}

beforeEach(() => {
  createDraftMock.mockReset();
  findByPhoneMock.mockReset().mockResolvedValue(null);
  findLibraryMock.mockReset().mockResolvedValue(null);
  searchLibraryMock.mockReset().mockResolvedValue([]);
});

describe("save_contact", () => {
  it("drafts a visiting card with a normalised phone", async () => {
    const res = await saveContactTool(CTX, {
      name: "Amit Shah",
      phone: "9876543210",
      company: "GEID",
      email: "amit@geid.test",
    });
    expect(res.ok).toBe(true);
    const data = lastDraft().data as Extract<DraftData, { kind: "saved_contact" }>;
    expect(data.phone).toBe("919876543210");
    expect(data.replacing).toBe(false);
    expect(lastDraft().title).toBe("Save contact");
  });

  it("marks an existing number as an update", async () => {
    findByPhoneMock.mockResolvedValue({ id: "c_old", name: "Amit", phone: "919876543210" });
    await saveContactTool(CTX, { name: "Amit Shah", phone: "9876543210" });
    const data = lastDraft().data as Extract<DraftData, { kind: "saved_contact" }>;
    expect(data.replacing).toBe(true);
    expect(data.existingId).toBe("c_old");
    expect(lastDraft().title).toBe("Update contact");
  });

  it("needs a name", async () => {
    const res = await saveContactTool(CTX, { phone: "9876543210" });
    expect(res.ok).toBe(false);
  });

  it("needs a phone or an email", async () => {
    const res = await saveContactTool(CTX, { name: "Amit" });
    expect(res.ok).toBe(false);
  });
});

describe("save_library_item", () => {
  it("drafts a rate card with its facts on the card", async () => {
    const res = await saveLibraryItemTool(CTX, {
      title: "GEID holographic rate card",
      kind: "rate_card",
      excerpt: "Holographic labels",
      facts: [{ label: "10k qty", value: "₹2.40 / pc" }],
      source_name: "rates.pdf",
      storage_path: "users/u1/agent_files/rates.pdf",
    });
    expect(res.ok).toBe(true);
    const data = lastDraft().data as Extract<DraftData, { kind: "library_item" }>;
    expect(data.libraryKind).toBe("rate_card");
    expect(data.facts).toEqual([{ label: "10k qty", value: "₹2.40 / pc" }]);
    expect(lastDraft().lines.map((l) => l.label)).toContain("10k qty");
  });

  it("needs something searchable", async () => {
    const res = await saveLibraryItemTool(CTX, { title: "x", kind: "brochure" });
    expect(res.ok).toBe(false);
  });
});

describe("search_library", () => {
  it("returns the rows the store found", async () => {
    searchLibraryMock.mockResolvedValue([
      {
        title: "GEID holographic rate card",
        kind: "rate_card",
        excerpt: "Holographic labels",
        facts: [{ label: "10k qty", value: "₹2.40 / pc" }],
        sourceName: "rates.pdf",
      },
    ]);
    const res = await searchLibraryTool(CTX, { query: "holographic" });
    expect(res.ok).toBe(true);
    const data = res.ok && res.kind === "data" ? (res.data as { count: number }) : { count: 0 };
    expect(data.count).toBe(1);
  });

  it("says so when the notebook has nothing", async () => {
    const res = await searchLibraryTool(CTX, { query: "zzz" });
    expect(res.ok === false && res.reason).toBe("nothing_found");
  });
});

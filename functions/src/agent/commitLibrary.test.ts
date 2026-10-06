import { beforeEach, expect, it, vi } from "vitest";

import type { AgentDraft } from "./draftTypes";

const saveContactMock = vi.fn();
const saveLibraryMock = vi.fn();
const draft = { current: null as AgentDraft | null };

vi.mock("./draftStore", () => ({
  getDraft: () => Promise.resolve(draft.current),
  markDraftStatus: () => Promise.resolve(),
}));
vi.mock("./clientResolve", () => ({ createClient: () => Promise.resolve({ id: "c", name: "c" }) }));
vi.mock("./google/workspace", async () => {
  const actual = await vi.importActual<typeof import("./google/workspace")>("./google/workspace");
  return { ...actual };
});
vi.mock("./contactStore", () => ({
  saveContact: (...a: unknown[]) => saveContactMock(...a),
}));
vi.mock("./libraryStore", () => ({
  saveLibraryItem: (...a: unknown[]) => saveLibraryMock(...a),
}));
vi.mock("firebase-admin/firestore", () => ({
  FieldValue: { serverTimestamp: () => "ts" },
  getFirestore: () => ({}),
}));

const { commitDraft } = await import("./commit");

beforeEach(() => {
  saveContactMock.mockReset();
  saveLibraryMock.mockReset();
});

it("writes a confirmed visiting card into the CRM contacts collection", async () => {
  saveContactMock.mockResolvedValue({
    id: "ct_1",
    name: "Amit Shah",
    company: "GEID",
    phone: "919876543210",
  });
  draft.current = {
    id: "d1",
    kind: "saved_contact",
    status: "pending",
    title: "Save contact",
    icon: "🪪",
    lines: [],
    data: {
      kind: "saved_contact",
      name: "Amit Shah",
      phone: "919876543210",
      company: "GEID",
      email: "amit@geid.test",
      notes: "BDM",
      replacing: false,
      existingId: null,
    },
    chatId: "c1",
    createdAtMs: 0,
    committedAtMs: null,
    resultIds: [],
  };

  const res = await commitDraft("u1", "d1");
  expect(res.ok).toBe(true);
  expect(res.createdIds).toEqual(["ct_1"]);
  expect(saveContactMock).toHaveBeenCalledWith("u1", {
    name: "Amit Shah",
    phone: "919876543210",
    company: "GEID",
    email: "amit@geid.test",
    notes: "BDM",
    source: "visiting_card",
    existingId: null,
  });
});

it("writes a confirmed library card into users/{uid}/library", async () => {
  saveLibraryMock.mockResolvedValue({
    id: "lib_1",
    title: "GEID holographic rate card",
    kind: "rate_card",
    facts: [{ label: "10k qty", value: "₹2.40 / pc" }],
  });
  draft.current = {
    id: "d2",
    kind: "library_item",
    status: "pending",
    title: "File this",
    icon: "📄",
    lines: [],
    data: {
      kind: "library_item",
      title: "GEID holographic rate card",
      libraryKind: "rate_card",
      sourceName: "rates.pdf",
      mimeType: "application/pdf",
      storagePath: "users/u1/agent_files/rates.pdf",
      excerpt: "Holographic labels",
      facts: [{ label: "10k qty", value: "₹2.40 / pc" }],
      replacing: false,
      existingId: null,
    },
    chatId: "c1",
    createdAtMs: 0,
    committedAtMs: null,
    resultIds: [],
  };

  const res = await commitDraft("u1", "d2");
  expect(res.ok).toBe(true);
  expect(res.createdIds).toEqual(["lib_1"]);
  expect(res.message).toContain("Filed");
  expect(saveLibraryMock).toHaveBeenCalledWith(
    "u1",
    expect.objectContaining({
      title: "GEID holographic rate card",
      kind: "rate_card",
    }),
  );
});

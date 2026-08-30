import { beforeEach, expect, it, vi } from "vitest";

import type { AgentDraft } from "./draftTypes";

/**
 * remember_fact used to answer "yaad rakh liya" and save nothing, because it
 * went through saveUserMemory — a helper the old chat pipeline deliberately
 * turned into a no-op. This pins the write down: same document getUserMemory
 * reads, merged rather than replaced.
 */

const setMock = vi.fn();
const path: string[] = [];
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

vi.mock("firebase-admin/firestore", () => {
  const node = {
    collection: (name: string) => {
      path.push(name);
      return node;
    },
    doc: (id?: string) => {
      path.push(id ?? "auto");
      return node;
    },
    get: () => Promise.resolve({ data: () => ({}) }),
    set: (...a: unknown[]) => {
      setMock(path.join("/"), ...a);
      return Promise.resolve();
    },
  };
  return { FieldValue: { serverTimestamp: () => "ts" }, getFirestore: () => node };
});

const { commitDraft } = await import("./commit");

beforeEach(() => {
  setMock.mockReset();
  path.length = 0;
});

it("writes the fact into the profile the next turn reads", async () => {
  draft.current = {
    id: "d1",
    kind: "remember_fact",
    status: "pending",
    title: "t",
    icon: "🧠",
    lines: [],
    data: { kind: "remember_fact", category: "city", fact: "Vasai East, Mumbai" },
    chatId: "c1",
    createdAtMs: 0,
    committedAtMs: null,
    resultIds: [],
  };

  const res = await commitDraft("u1", "d1");
  expect(res.ok).toBe(true);

  const [writtenPath, payload, options] = setMock.mock.calls.at(-1)!;
  expect(writtenPath).toBe("users/u1/memory/profile");
  expect(payload).toMatchObject({ city: "Vasai East, Mumbai" });
  // Merge, or remembering a second thing would erase the first.
  expect(options).toEqual({ merge: true });
});

it("gives each fact its own key, so a second family detail keeps the first", async () => {
  draft.current = {
    id: "d2",
    kind: "remember_fact",
    status: "pending",
    title: "t",
    icon: "🧠",
    lines: [],
    data: {
      kind: "remember_fact",
      category: "wife",
      fact: "Ruchi Singh, born 19 Oct 1995",
      facts: [
        { key: "wife", value: "Ruchi Singh, born 19 Oct 1995" },
        { key: "daughter", value: "Prisha Singh, born 16 Sep 2020" },
        { key: "son", value: "Advik Singh, called Ivaan, born 6 Dec 2023" },
      ],
    },
    chatId: "c1",
    createdAtMs: 0,
    committedAtMs: null,
    resultIds: [],
  };

  const res = await commitDraft("u1", "d2");
  expect(res.ok).toBe(true);

  const [writtenPath, payload, options] = setMock.mock.calls.at(-1)!;
  expect(writtenPath).toBe("users/u1/memory/profile");
  // Filed by category, all three would have collided on one "family" key.
  expect(payload).toMatchObject({
    wife: "Ruchi Singh, born 19 Oct 1995",
    daughter: "Prisha Singh, born 16 Sep 2020",
    son: "Advik Singh, called Ivaan, born 6 Dec 2023",
  });
  expect(options).toEqual({ merge: true });
});

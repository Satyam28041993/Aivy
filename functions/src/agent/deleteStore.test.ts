/**
 * Delete only what was meant, keep a copy first, and take the reminders with
 * it — the three things that would hurt if they went wrong.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";

type Doc = Record<string, unknown>;
const store = new Map<string, Doc>();
let auto = 0;
const DELETE = { __delete: true };

function docRef(path: string): any {
  return {
    id: path.split("/").pop()!,
    path,
    get: async () => ({
      exists: store.has(path),
      id: path.split("/").pop()!,
      ref: docRef(path),
      data: () => store.get(path),
      get: (f: string) => store.get(path)?.[f],
    }),
    set: async (d: Doc, o?: { merge?: boolean }) =>
      void store.set(path, o?.merge ? { ...(store.get(path) ?? {}), ...d } : { ...d }),
    update: async (d: Doc) => {
      const next = { ...(store.get(path) ?? {}) };
      for (const [k, v] of Object.entries(d)) {
        if (v === DELETE) delete next[k];
        else next[k] = v;
      }
      store.set(path, next);
    },
    delete: async () => void store.delete(path),
    collection: (name: string) => collRef(`${path}/${name}`),
  };
}

function collRef(path: string): any {
  const filters: Array<(d: Doc) => boolean> = [];
  let order: string | null = null;
  const q: any = {
    doc: (id?: string) => docRef(`${path}/${id ?? `auto${++auto}`}`),
    where(f: string, _op: string, v: unknown) {
      filters.push((d) => d[f] === v);
      return q;
    },
    orderBy(f: string) {
      order = f;
      return q;
    },
    limit: () => q,
    async get() {
      let docs = [...store.entries()]
        .filter(([k]) => k.startsWith(`${path}/`) && !k.slice(path.length + 1).includes("/"))
        .map(([k, d]) => ({ id: k.split("/").pop()!, ref: docRef(k), data: () => d }))
        .filter((x) => filters.every((f) => f(x.data())));
      if (order) docs = docs.sort((a, b) => ((b.data()[order!] as number) ?? 0) - ((a.data()[order!] as number) ?? 0));
      return { docs, empty: docs.length === 0 };
    },
  };
  return q;
}

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({ collection: (n: string) => collRef(n), doc: (p: string) => docRef(p) }),
  FieldValue: { delete: () => DELETE },
}));
vi.mock("firebase-functions", () => ({ logger: { warn: vi.fn() } }));
const updateRow = vi.fn();
vi.mock("./google/workspace", async () => {
  const actual = await vi.importActual<typeof import("./google/workspace")>("./google/workspace");
  return { ...actual, sheetsUpdateRow: (...a: unknown[]) => updateRow(...a) };
});

const { findDeleteTargets, deleteTarget, restoreFromTrash, matchesQuery } = await import("./deleteStore");
const TZ = { timezone: "Asia/Kolkata" };

beforeEach(() => {
  store.clear();
  updateRow.mockReset().mockResolvedValue(undefined);
});

describe("finding what to delete", () => {
  it("needs every word to match", () => {
    expect(matchesQuery(["Call Sharma about BX410T"], "sharma call")).toBe(true);
    expect(matchesQuery(["Call Sharma"], "sharma bajaj")).toBe(false);
    expect(matchesQuery(["Call Sharma"], "")).toBe(false);
  });

  it("finds pending reminders only", async () => {
    store.set("users/u/reminders/r1", { title: "Call Sharma", status: "pending", scheduledTimeMs: 1 });
    store.set("users/u/reminders/r2", { title: "Call Sharma", status: "done", scheduledTimeMs: 2 });
    const t = await findDeleteTargets("u", "reminder", "sharma", TZ);
    expect(t.map((x) => x.path)).toEqual(["users/u/reminders/r1"]);
  });

  it("returns every match so the tool can ask which", async () => {
    store.set("users/u/visits/v1", { clientName: "Bajaj Auto", dateLabel: "05-Oct-2026", visitDateMs: 1 });
    store.set("users/u/visits/v2", { clientName: "Bajaj Auto", dateLabel: "06-Oct-2026", visitDateMs: 2 });
    expect(await findDeleteTargets("u", "visit", "bajaj", TZ)).toHaveLength(2);
    expect(await findDeleteTargets("u", "visit", "bajaj", { ...TZ, id: "v1" })).toHaveLength(1);
  });

  it("never offers a payment that already has money against it", async () => {
    store.set("users/u/payments/p1", { clientName: "Exide", amount: 5000, paidAmount: 2000, remainingAmount: 3000 });
    store.set("users/u/payments/p2", { clientName: "Exide", amount: 4000, paidAmount: 0, remainingAmount: 4000 });
    const t = await findDeleteTargets("u", "payment_due", "exide", TZ);
    expect(t.map((x) => x.path)).toEqual(["users/u/payments/p2"]);
  });

  it("only sees this user's contacts", async () => {
    store.set("contacts/c1", { ownerUid: "u", name: "Amit Shah" });
    store.set("contacts/c2", { ownerUid: "other", name: "Amit Shah" });
    const t = await findDeleteTargets("u", "contact", "amit", TZ);
    expect(t.map((x) => x.path)).toEqual(["contacts/c1"]);
  });
});

describe("all of a kind, and clients", () => {
  it("'jo bhi orders hai sab' finds every order with no words given", async () => {
    store.set("users/u/orders/o1", { clientName: "Exide", amount: 100, createdAtMs: 1 });
    store.set("users/u/orders/o2", { clientName: "Bajaj", amount: 200, createdAtMs: 2 });
    expect(await findDeleteTargets("u", "order", "", { ...TZ, all: true })).toHaveLength(2);
    expect(await findDeleteTargets("u", "order", "", TZ)).toHaveLength(0);
  });

  it("deletes a client's entry and says its records stay", async () => {
    store.set("users/u/clients/c1", { name: "Bajaj Auto" });
    store.set("users/u/quotations/q1", { clientId: "c1", clientName: "Bajaj Auto", amount: 5 });
    const [t] = await findDeleteTargets("u", "client", "bajaj", TZ);
    expect(t!.label).toMatch(/1 linked record stay/);
    await deleteTarget("u", t!);
    expect(store.has("users/u/clients/c1")).toBe(false);
    expect(store.has("users/u/quotations/q1")).toBe(true);
  });
});

describe("deleting", () => {
  it("keeps a copy in trash, cancels the follow-up, blanks the DSR row — and can bring it back", async () => {
    store.set("users/u/meta/dsr", { spreadsheetId: "S1" });
    store.set("users/u/visits/v1", { clientName: "Bajaj Auto", dateLabel: "06-Oct-2026", followUpReminderId: "r9", sheetRow: 7 });
    store.set("users/u/reminders/r9", { title: "Follow-up: Bajaj", status: "pending" });
    const [t] = await findDeleteTargets("u", "visit", "bajaj", TZ);
    const out = await deleteTarget("u", t!, { googleToken: "tok" });

    expect(store.has("users/u/visits/v1")).toBe(false);
    expect(store.get(`users/u/trash/${out.trashId}`)?.path).toBe("users/u/visits/v1");
    expect(store.get("users/u/reminders/r9")?.status).toBe("cancelled");
    expect(updateRow).toHaveBeenCalledWith("tok", expect.objectContaining({ spreadsheetId: "S1", row: 7 }));

    await restoreFromTrash("u", out.trashId);
    expect(store.get("users/u/visits/v1")?.clientName).toBe("Bajaj Auto");
    expect(store.get("users/u/visits/v1")?.sheetFollowUpPending).toBe(true);
  });

  it("takes a task's steps with it, into the same trash entry", async () => {
    store.set("users/u/projects/p1", { name: "Send samples", kind: "task", reminderIds: ["r1"] });
    store.set("users/u/projects/p1/items/i1", { title: "Pack", reminderId: "r2" });
    store.set("users/u/reminders/r1", { status: "pending" });
    store.set("users/u/reminders/r2", { status: "pending" });
    const [t] = await findDeleteTargets("u", "task", "samples", TZ);
    const out = await deleteTarget("u", t!);
    expect(store.has("users/u/projects/p1/items/i1")).toBe(false);
    expect((store.get(`users/u/trash/${out.trashId}`)?.items as unknown[]).length).toBe(1);
    expect(store.get("users/u/reminders/r1")?.status).toBe("cancelled");
    expect(store.get("users/u/reminders/r2")?.status).toBe("cancelled");
  });

  it("removes one remembered fact, not the whole profile", async () => {
    store.set("users/u/memory/profile", { city: "Aurangabad", employer: "Prakruti" });
    const [t] = await findDeleteTargets("u", "remembered_fact", "prakruti", TZ);
    await deleteTarget("u", t!);
    expect(store.get("users/u/memory/profile")).toEqual(expect.objectContaining({ city: "Aurangabad" }));
    expect(store.get("users/u/memory/profile")?.employer).toBeUndefined();
  });

  it("refuses another user's contact even with its path", async () => {
    store.set("contacts/c2", { ownerUid: "other", name: "X" });
    await expect(
      deleteTarget("u", { kind: "contact", path: "contacts/c2", label: "X", reminderIds: [], reminderLinks: [] }),
    ).rejects.toThrow();
    expect(store.has("contacts/c2")).toBe(true);
  });
});

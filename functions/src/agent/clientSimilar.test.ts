/**
 * "Exide Industries Chikalthana" when "Exide Industries" already exists: a
 * live run made two clients of one company. Now it is asked, not guessed.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";

const clients = { current: [] as Array<{ id: string; name: string }> };
vi.mock("firebase-admin/firestore", () => ({
  FieldValue: {},
  getFirestore: () => ({
    collection: () => ({
      doc: () => ({
        collection: () => ({
          get: async () => ({
            docs: clients.current.map((c) => ({ id: c.id, data: () => ({ name: c.name }) })),
          }),
        }),
      }),
    }),
  }),
}));
vi.mock("firebase-functions", () => ({ logger: { warn: vi.fn() } }));

const { resolveClient } = await import("./clientResolve");
const { referenceClient } = await import("./tools/writeTools");

const CTX = { uid: "u", timezone: "Asia/Kolkata", nowIso: "2026-10-06T12:00:00+05:30", chatId: "c" };

beforeEach(() => {
  clients.current = [
    { id: "c1", name: "Exide Industries" },
    { id: "c2", name: "Bajaj Auto" },
  ];
});

describe("a longer name for an existing client", () => {
  it("is reported as similar, not new", async () => {
    const r = await resolveClient("u", "Exide Industries Chikalthana");
    expect(r.status).toBe("similar");
  });

  it("does not match a name that merely shares a first word", async () => {
    const r = await resolveClient("u", "Exidee Power");
    expect(r.status).toBe("not_found");
  });

  it("makes a write tool ask same-or-separate", async () => {
    const r = await referenceClient(CTX, "Exide Industries Chikalthana", true);
    expect("failure" in r).toBe(true);
    if ("failure" in r && !r.failure.ok) {
      expect(r.failure.reason).toBe("needs_client_choice");
      expect(r.failure.message).toContain('"Exide Industries"');
      expect(r.failure.message).toContain("(new)");
    }
  });

  it("creates a separate client when the answer was '(new)'", async () => {
    const r = await referenceClient(CTX, "Exide Industries Chikalthana (new)", true);
    expect(r).toEqual({ ref: { id: null, name: "Exide Industries Chikalthana", createNew: true } });
  });

  it("still finds the existing one by its own name", async () => {
    const r = await referenceClient(CTX, "Exide Industries", true);
    expect(r).toEqual({ ref: { id: "c1", name: "Exide Industries", createNew: false } });
  });
});

/**
 * read_document: a spec question is answered from the brochure's own text,
 * and an unreadable brochure is admitted, not papered over.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";

const library: Record<string, Record<string, unknown>> = {};
const texts: Record<string, Record<string, unknown>> = {};

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: (name: string) => ({
      get: async () => ({
        docs: Object.entries(name === "brochures" ? library : texts).map(([id, d]) => ({
          id,
          data: () => d,
        })),
      }),
      doc: (id: string) => ({
        get: async () => ({ data: () => (name === "brochures" ? library : texts)[id] }),
      }),
    }),
  }),
}));

vi.mock("firebase-functions", () => ({ logger: { warn: vi.fn() } }));

import { readDocumentTool } from "./brochures";

const CTX = { uid: "u", timezone: "Asia/Kolkata", nowIso: "2026-10-05T10:00:00Z", chatId: null };

beforeEach(() => {
  for (const k of Object.keys(library)) delete library[k];
  for (const k of Object.keys(texts)) delete texts[k];
  library["1iwdLopdtLYkGyqG5q2eDg1E5qXrjg7VO"] = {
    title: "Toshiba BV400", fileName: "Toshiba BV400.pdf", category: "Printer", url: "https://x/bv400",
  };
  library["1FyjaQ3I1FNWBeikWLjSqLH6Xp2Tw81rP"] = {
    title: "DS-3678 BT", fileName: "DS-3678 BT.pdf", category: "Scanner", url: "https://x/ds3678",
  };
  texts["1iwdLopdtLYkGyqG5q2eDg1E5qXrjg7VO"] = {
    readable: true, text: "Max. print width GS02 108 mm. Max. print speed 7 ips.",
  };
  texts["1FyjaQ3I1FNWBeikWLjSqLH6Xp2Tw81rP"] = { readable: false, text: "" };
});

describe("read_document", () => {
  it("returns the brochure's own text for a spec question", async () => {
    const res = await readDocumentTool(CTX, { query: "BV400 max label width" });
    expect(res.ok).toBe(true);
    const data = (res as { data: { text: string; document: { link: string } } }).data;
    expect(data.text).toContain("108 mm");
    expect(data.document.link).toBe("https://x/bv400");
  });

  it("says so when the brochure could not be read", async () => {
    const res = await readDocumentTool(CTX, { query: "DS3678" });
    const data = (res as { data: { text: string | null; note: string } }).data;
    expect(data.text).toBeNull();
    expect(data.note).toMatch(/could not be read/);
  });

  it("asks what to read when given nothing", async () => {
    const res = await readDocumentTool(CTX, { query: "" });
    expect(res.ok).toBe(false);
  });

  it("does not read a random file for an unknown product", async () => {
    const res = await readDocumentTool(CTX, { query: "coffee machine" });
    expect(res.ok).toBe(false);
  });
});

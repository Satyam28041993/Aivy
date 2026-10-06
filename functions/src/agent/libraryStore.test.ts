import { beforeEach, describe, expect, it, vi } from "vitest";

const docs: Array<Record<string, unknown>> = [];
const setMock = vi.fn();

function upsert(data: Record<string, unknown>) {
  setMock(data);
  const at = docs.findIndex((d) => d.id === data.id);
  if (at >= 0) {
    docs[at] = data;
  } else {
    docs.push(data);
  }
  return Promise.resolve();
}

vi.mock("firebase-admin/firestore", () => {
  function libraryCollection() {
    const filters: Array<{ field: string; value: unknown }> = [];
    const q: Record<string, unknown> = {
      where: (field: string, _op: string, value: unknown) => {
        filters.push({ field, value });
        return q;
      },
      orderBy: () => q,
      limit: () => q,
      get: () => {
        let rows = docs;
        for (const f of filters) {
          rows = rows.filter((d) => d[f.field] === f.value);
        }
        return Promise.resolve({
          empty: rows.length === 0,
          docs: rows.map((d) => ({
            id: d.id as string,
            data: () => d,
          })),
        });
      },
      doc: (id?: string) => {
        const docId = id ?? `new_${docs.length + 1}`;
        return {
          id: docId,
          get: () => {
            const found = docs.find((d) => d.id === docId);
            return Promise.resolve({ exists: !!found, data: () => found });
          },
          set: (data: Record<string, unknown>) => upsert({ ...data, id: docId }),
        };
      },
    };
    return q;
  }

  return {
    getFirestore: () => ({
      collection: () => ({ doc: () => ({ collection: () => libraryCollection() }) }),
    }),
  };
});

const { saveLibraryItem, searchLibrary } = await import("./libraryStore");

beforeEach(() => {
  docs.length = 0;
  setMock.mockReset();
});

describe("saving", () => {
  it("keeps the facts that search will need later", async () => {
    const item = await saveLibraryItem("u1", {
      title: "GEID holographic rate card",
      kind: "rate_card",
      excerpt: "Holographic labels, 10k qty.",
      facts: [
        { label: "10k qty", value: "₹2.40 / pc" },
        { label: "MOQ", value: "5000" },
      ],
      sourceName: "rates.pdf",
    });
    expect(item.searchText).toContain("2.40");
    expect(item.searchText).toContain("holographic");
    expect(item.facts).toHaveLength(2);
  });

  it("replaces the same title and kind rather than stacking", async () => {
    const first = await saveLibraryItem("u1", {
      title: "GEID rate card",
      kind: "rate_card",
      excerpt: "old",
      facts: [{ label: "10k", value: "2.10" }],
    });
    const second = await saveLibraryItem("u1", {
      title: "GEID rate card",
      kind: "rate_card",
      excerpt: "new",
      facts: [{ label: "10k", value: "2.40" }],
    });
    expect(second.id).toBe(first.id);
    expect(docs).toHaveLength(1);
    expect((docs[0] as { excerpt: string }).excerpt).toBe("new");
  });

  it("drops empty facts rather than writing blanks", async () => {
    const item = await saveLibraryItem("u1", {
      title: "Training day 1",
      kind: "training",
      excerpt: "Security labels intro",
      facts: [{ label: "", value: "x" }, { label: "Trainer", value: "Mandar" }],
    });
    expect(item.facts).toEqual([{ label: "Trainer", value: "Mandar" }]);
  });
});

describe("search", () => {
  beforeEach(async () => {
    await saveLibraryItem("u1", {
      title: "GEID holographic rate card",
      kind: "rate_card",
      excerpt: "Holographic labels",
      facts: [{ label: "10k qty", value: "₹2.40 / pc" }],
    });
    await saveLibraryItem("u1", {
      title: "BDM training week 1",
      kind: "training",
      excerpt: "How to pitch security labels",
      facts: [{ label: "Trainer", value: "Mandar sir" }],
    });
  });

  it("finds a rate by the words on the page, not the file name", async () => {
    const rows = await searchLibrary("u1", "holographic 2.40");
    expect(rows[0]?.title).toBe("GEID holographic rate card");
  });

  it("finds training by a name mentioned inside it", async () => {
    const rows = await searchLibrary("u1", "mandar pitch");
    expect(rows[0]?.kind).toBe("training");
  });

  it("returns nothing for an unknown term", async () => {
    expect(await searchLibrary("u1", "zzzunknown")).toEqual([]);
  });
});

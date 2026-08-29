import { beforeEach, describe, expect, it, vi } from "vitest";

/**
 * A saved place is the one record whose *name* is the whole interface — the
 * user says "Rohan Office" months later and expects the same point back. So
 * these pin down matching and the overwrite rule rather than the storage shape.
 */

const docs: Array<Record<string, unknown>> = [];
const setMock = vi.fn();
const deleteMock = vi.fn();

/** Writes like Firestore's set(): replace the doc with this id, or append it. */
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

function snapOf(rows: Array<Record<string, unknown>>) {
  return {
    empty: rows.length === 0,
    docs: rows.map((d) => ({
      data: () => d,
      ref: { id: d.id as string, set: upsert },
    })),
  };
}

vi.mock("firebase-admin/firestore", () => {
  function placesCollection() {
    let filterKey: string | null = null;
    const q: Record<string, unknown> = {
      where: (_f: string, _op: string, v: string) => {
        filterKey = v;
        return q;
      },
      orderBy: () => q,
      limit: () => q,
      get: () =>
        Promise.resolve(
          snapOf(filterKey == null ? docs : docs.filter((d) => d.nameKey === filterKey)),
        ),
      doc: (id?: string) => ({
        id: id ?? `new_${docs.length + 1}`,
        set: upsert,
        delete: () => {
          deleteMock(id);
          const at = docs.findIndex((d) => d.id === id);
          if (at >= 0) {
            docs.splice(at, 1);
          }
          return Promise.resolve();
        },
      }),
    };
    return q;
  }

  // users -> doc(uid) -> places
  return {
    getFirestore: () => ({
      collection: () => ({ doc: () => ({ collection: () => placesCollection() }) }),
    }),
  };
});

const { deleteSavedPlace, findSavedPlace, savePlace } = await import("./placesStore");

beforeEach(() => {
  docs.length = 0;
  setMock.mockReset();
  deleteMock.mockReset();
});

describe("saving", () => {
  it("keeps the point and a map link", async () => {
    const p = await savePlace("u1", {
      name: "Rohan Office",
      lat: 19.3919,
      lng: 72.8397,
      address: "Vasai East",
    });
    expect(p.lat).toBe(19.3919);
    expect(p.mapsLink).toBe(
      "https://www.google.com/maps/search/?api=1&query=19.3919,72.8397",
    );
  });

  it("moves a place rather than saving a second one with the same name", async () => {
    const first = await savePlace("u1", { name: "Godown", lat: 1, lng: 1 });
    const second = await savePlace("u1", { name: "godown", lat: 2, lng: 2 });
    expect(second.id).toBe(first.id);
    expect(docs).toHaveLength(1);
    expect((docs[0] as { lat: number }).lat).toBe(2);
  });

  it("survives a missing address", async () => {
    const p = await savePlace("u1", { name: "Ghar", lat: 1, lng: 1 });
    expect(p.address).toBe("");
  });
});

describe("finding", () => {
  beforeEach(async () => {
    await savePlace("u1", { name: "Rohan Office", lat: 1, lng: 1 });
    await savePlace("u1", { name: "Mehta Godown", lat: 2, lng: 2 });
  });

  it("matches however the name is typed", async () => {
    for (const q of ["Rohan Office", "rohan office", "ROHAN  OFFICE"]) {
      expect((await findSavedPlace("u1", q))?.name).toBe("Rohan Office");
    }
  });

  it("matches a partial name when only one place fits", async () => {
    expect((await findSavedPlace("u1", "mehta"))?.name).toBe("Mehta Godown");
  });

  it("refuses to guess when two places fit", async () => {
    await savePlace("u1", { name: "Rohan Godown", lat: 3, lng: 3 });
    expect(await findSavedPlace("u1", "rohan")).toBeNull();
  });

  it("returns nothing for an unknown name", async () => {
    expect(await findSavedPlace("u1", "zzz")).toBeNull();
  });
});

describe("forgetting", () => {
  it("removes a place it can find, and reports when it cannot", async () => {
    await savePlace("u1", { name: "Ghar", lat: 1, lng: 1 });
    expect(await deleteSavedPlace("u1", "ghar")).toBe(true);
    expect(deleteMock).toHaveBeenCalled();
    expect(await deleteSavedPlace("u1", "nowhere")).toBe(false);
  });
});

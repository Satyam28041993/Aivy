import { beforeEach, describe, expect, it, vi } from "vitest";

const docs: Array<Record<string, unknown>> = [];
const setMock = vi.fn();

function upsert(data: Record<string, unknown>, merge?: { merge?: boolean }) {
  setMock(data, merge);
  const id = data.id as string | undefined;
  const at = id ? docs.findIndex((d) => d.id === id) : -1;
  if (at >= 0) {
    docs[at] = { ...docs[at], ...data };
  } else {
    docs.push(data);
  }
  return Promise.resolve();
}

vi.mock("firebase-admin/firestore", () => {
  function contactsCollection() {
    const filters: Array<{ field: string; value: unknown }> = [];
    const q: Record<string, unknown> = {
      where: (field: string, _op: string, value: unknown) => {
        filters.push({ field, value });
        return q;
      },
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
          set: (data: Record<string, unknown>, opts?: { merge?: boolean }) =>
            upsert({ ...data, id: docId }, opts),
        };
      },
    };
    return q;
  }

  return {
    FieldValue: { serverTimestamp: () => "ts" },
    getFirestore: () => ({
      collection: () => contactsCollection(),
    }),
  };
});

const { findContactByPhone, normalizeIndiaPhone, saveContact, searchCrmContacts } =
  await import("./contactStore");

beforeEach(() => {
  docs.length = 0;
  setMock.mockReset();
});

describe("normalizeIndiaPhone", () => {
  it("adds 91 to a 10-digit number", () => {
    expect(normalizeIndiaPhone("98765 43210")).toBe("919876543210");
  });

  it("keeps an already-prefixed number", () => {
    expect(normalizeIndiaPhone("919876543210")).toBe("919876543210");
  });

  it("rejects a short number", () => {
    expect(normalizeIndiaPhone("12345")).toBeNull();
  });
});

describe("saving", () => {
  it("writes the Flutter contact shape", async () => {
    const c = await saveContact("u1", {
      name: "Amit Shah",
      phone: "9876543210",
      company: "GEID",
      email: "amit@geid.test",
      notes: "BDM, Vasai",
      source: "visiting_card",
    });
    expect(c.phone).toBe("919876543210");
    expect(c.nameLower).toBe("amit shah");
    const written = setMock.mock.calls[0]![0] as Record<string, unknown>;
    expect(written).toMatchObject({
      ownerUid: "u1",
      name: "Amit Shah",
      nameLower: "amit shah",
      phone: "919876543210",
      company: "GEID",
      source: "visiting_card",
    });
  });

  it("updates the same phone instead of stacking a second card", async () => {
    const first = await saveContact("u1", { name: "Amit", phone: "9876543210", company: "Old" });
    const second = await saveContact("u1", { name: "Amit Shah", phone: "9876543210", company: "GEID" });
    expect(second.id).toBe(first.id);
    expect(docs).toHaveLength(1);
    expect(docs[0]!.company).toBe("GEID");
  });
});

describe("finding", () => {
  beforeEach(async () => {
    await saveContact("u1", { name: "Amit Shah", phone: "9876543210", company: "GEID" });
    await saveContact("u1", { name: "Rohan Traders", phone: "912345678900" });
  });

  it("matches a name however it is typed", async () => {
    expect((await searchCrmContacts("u1", "amit"))[0]?.name).toBe("Amit Shah");
    expect((await searchCrmContacts("u1", "SHAH"))[0]?.name).toBe("Amit Shah");
  });

  it("matches a company", async () => {
    expect((await searchCrmContacts("u1", "geid"))[0]?.name).toBe("Amit Shah");
  });

  it("matches enough of a phone number", async () => {
    expect((await findContactByPhone("u1", "9876543210"))?.name).toBe("Amit Shah");
    expect((await searchCrmContacts("u1", "98765"))[0]?.name).toBe("Amit Shah");
  });

  it("returns nothing for an unknown name", async () => {
    expect(await searchCrmContacts("u1", "zzz")).toEqual([]);
  });
});

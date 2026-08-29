import { beforeEach, expect, it, vi } from "vitest";

/**
 * Firestore throws on `undefined`, and the tool payload stored with every
 * assistant message comes straight from the tools — where `x || undefined` is
 * the ordinary way to say "omit this". That combination took the whole turn
 * down with a bare INTERNAL, after the reply had already been produced.
 */

const setMock = vi.fn();

vi.mock("firebase-admin/firestore", () => {
  const node = {
    collection: () => node,
    doc: () => ({ ...node, id: "m1" }),
    set: (data: unknown) => {
      setMock(data);
      return Promise.resolve();
    },
  };
  return { getFirestore: () => node };
});

const { appendMessage } = await import("./chatStore");

function hasUndefined(value: unknown): boolean {
  if (Array.isArray(value)) {
    return value.some(hasUndefined);
  }
  if (value && typeof value === "object") {
    return Object.values(value).some((v) => v === undefined || hasUndefined(v));
  }
  return false;
}

beforeEach(() => setMock.mockReset());

it("drops undefined anywhere in the stored tool payload", async () => {
  await appendMessage("u1", "c1", {
    role: "assistant",
    text: "kal calendar par ye hai",
    modelParts: [
      {
        role: "user",
        parts: [
          {
            functionResponse: {
              name: "list_calendar_events",
              response: {
                ok: true,
                data: {
                  window: "kal",
                  events: [
                    { title: "Meeting", when: "11:00 AM", location: undefined },
                    { title: "Call", when: "3:00 PM", location: "Office" },
                  ],
                },
              },
            },
          },
        ],
      },
    ],
  });

  const written = setMock.mock.calls.at(-1)![0] as Record<string, unknown>;
  expect(hasUndefined(written)).toBe(false);

  // Dropping the key must not flatten everything else with it.
  const events = (
    (written.modelParts as Array<{ parts: Array<{ functionResponse: { response: { data: { events: Array<Record<string, unknown>> } } } }> }>)[0]!
      .parts[0]!.functionResponse.response.data
  ).events;
  expect(events[0]).toEqual({ title: "Meeting", when: "11:00 AM" });
  expect(events[1]!.location).toBe("Office");
});

it("keeps a message with no tool payload intact", async () => {
  await appendMessage("u1", "c1", { role: "user", text: "hello" });
  const written = setMock.mock.calls.at(-1)![0] as Record<string, unknown>;
  expect(written).toMatchObject({ role: "user", text: "hello", drafts: [], modelParts: null });
});

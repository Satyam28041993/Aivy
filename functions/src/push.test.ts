import { beforeEach, describe, expect, it, vi } from "vitest";

/**
 * Push is delivery, not record-keeping: it must never throw back into the
 * reminder that triggered it, and it must clean up after itself when a phone
 * stops existing.
 */

const sendMock = vi.fn();
const getMock = vi.fn();
const deleteMock = vi.fn();
const deletedIds: string[] = [];

vi.mock("firebase-admin/messaging", () => ({
  getMessaging: () => ({ sendEachForMulticast: (...a: unknown[]) => sendMock(...a) }),
}));

vi.mock("firebase-admin/firestore", () => {
  const node = {
    collection: () => node,
    doc: (id?: string) => ({
      collection: () => node,
      get: () => getMock(),
      delete: () => {
        deletedIds.push(id ?? "");
        return deleteMock();
      },
    }),
    get: () => getMock(),
  };
  return { getFirestore: () => node };
});

const { pushToUser, tokenDocId } = await import("./push");

function devices(...tokens: string[]) {
  return { docs: tokens.map((token) => ({ data: () => ({ token }) })) };
}

beforeEach(() => {
  sendMock.mockReset();
  getMock.mockReset();
  deleteMock.mockReset().mockResolvedValue(undefined);
  deletedIds.length = 0;
});

describe("pushToUser", () => {
  it("sends to every registered device on the reminder channel", async () => {
    getMock.mockResolvedValue(devices("tok_a", "tok_b"));
    sendMock.mockResolvedValue({
      successCount: 2,
      failureCount: 0,
      responses: [{ success: true }, { success: true }],
    });

    const sent = await pushToUser("u1", { title: "Mummy ki dawa", body: "7 pm" });

    expect(sent).toBe(2);
    const msg = sendMock.mock.calls[0]![0] as Record<string, never>;
    expect(msg).toMatchObject({
      tokens: ["tok_a", "tok_b"],
      notification: { title: "Mummy ki dawa", body: "7 pm" },
      // High priority on the app's own channel, or Android may hold it back
      // and it arrives quietly, late, or not at all while the phone is dozing.
      android: { priority: "high", notification: { channelId: "aivy_reminders_v2" } },
    });
  });

  it("does not send, or fail, when no device is registered", async () => {
    getMock.mockResolvedValue(devices());
    expect(await pushToUser("u1", { title: "t", body: "b" })).toBe(0);
    expect(sendMock).not.toHaveBeenCalled();
  });

  it("forgets a token whose app was uninstalled", async () => {
    getMock.mockResolvedValue(devices("live", "dead"));
    sendMock.mockResolvedValue({
      successCount: 1,
      failureCount: 1,
      responses: [
        { success: true },
        { success: false, error: { code: "messaging/registration-token-not-registered" } },
      ],
    });

    await pushToUser("u1", { title: "t", body: "b" });
    expect(deletedIds).toEqual([tokenDocId("dead")]);
  });

  it("keeps a token that failed for a passing reason", async () => {
    getMock.mockResolvedValue(devices("tok"));
    sendMock.mockResolvedValue({
      successCount: 0,
      failureCount: 1,
      responses: [{ success: false, error: { code: "messaging/internal-error" } }],
    });

    await pushToUser("u1", { title: "t", body: "b" });
    expect(deletedIds).toEqual([]);
  });

  it("swallows a send failure rather than breaking the reminder", async () => {
    getMock.mockResolvedValue(devices("tok"));
    sendMock.mockRejectedValue(new Error("FCM down"));
    await expect(pushToUser("u1", { title: "t", body: "b" })).resolves.toBe(0);
  });

  it("swallows a Firestore failure the same way", async () => {
    getMock.mockRejectedValue(new Error("no permission"));
    await expect(pushToUser("u1", { title: "t", body: "b" })).resolves.toBe(0);
  });
});

describe("tokenDocId", () => {
  it("matches the id the app writes under", () => {
    expect(tokenDocId("abc/def:ghi.jkl")).toBe("abcdefghijkl");
    expect(tokenDocId("a-b_c")).toBe("a-b_c");
    expect(tokenDocId("x".repeat(300))).toHaveLength(120);
    expect(tokenDocId("///")).toBe("device");
  });
});

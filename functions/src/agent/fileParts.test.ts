import { beforeEach, describe, expect, it, vi } from "vitest";

const downloadMock = vi.fn();

vi.mock("firebase-admin/storage", () => ({
  getStorage: () => ({
    bucket: () => ({
      file: (path: string) => ({
        download: () => downloadMock(path),
      }),
    }),
  }),
}));

const {
  historyLineForAttachments,
  loadInlineParts,
  ownedAgentFilePath,
  parseAttachmentRefs,
  normalizeAttachmentMime,
} = await import("./fileParts");

beforeEach(() => {
  downloadMock.mockReset();
});

describe("ownedAgentFilePath", () => {
  it("accepts a file this user uploaded", () => {
    expect(ownedAgentFilePath("u1", "users/u1/agent_files/123_card.jpg")).toBe(
      "users/u1/agent_files/123_card.jpg",
    );
  });

  it("strips a leading slash", () => {
    expect(ownedAgentFilePath("u1", "/users/u1/agent_files/a.pdf")).toBe(
      "users/u1/agent_files/a.pdf",
    );
  });

  it("refuses another user's path", () => {
    expect(ownedAgentFilePath("u1", "users/u2/agent_files/x.jpg")).toBeNull();
  });

  it("refuses a path that walks out of the prefix", () => {
    expect(ownedAgentFilePath("u1", "users/u1/agent_files/../secrets.txt")).toBeNull();
    expect(ownedAgentFilePath("u1", "users/u1/memory/profile")).toBeNull();
  });

  it("refuses spaces and odd characters the client should have stripped", () => {
    expect(ownedAgentFilePath("u1", "users/u1/agent_files/my card.jpg")).toBeNull();
  });
});

describe("mime and refs", () => {
  it("treats image/jpg as jpeg", () => {
    expect(normalizeAttachmentMime("image/jpg")).toBe("image/jpeg");
  });

  it("rejects excel and powerpoint", () => {
    expect(normalizeAttachmentMime("application/vnd.ms-excel")).toBeNull();
    expect(normalizeAttachmentMime("application/vnd.ms-powerpoint")).toBeNull();
  });

  it("keeps at most three well-formed attachments", () => {
    const refs = parseAttachmentRefs([
      { storagePath: "users/u1/agent_files/a.jpg", mimeType: "image/jpeg", name: "a.jpg" },
      { storagePath: "users/u1/agent_files/b.pdf", mimeType: "application/pdf", name: "b.pdf" },
      { storagePath: "users/u1/agent_files/c.png", mimeType: "image/png", name: "c.png" },
      { storagePath: "users/u1/agent_files/d.jpg", mimeType: "image/jpeg", name: "d.jpg" },
      { storagePath: "", mimeType: "image/jpeg" },
    ]);
    expect(refs).toHaveLength(3);
    expect(refs[0]!.name).toBe("a.jpg");
  });
});

describe("history line", () => {
  it("keeps the words and the filenames, never the bytes", () => {
    expect(historyLineForAttachments("ye card save kar lo", ["card.jpg"])).toBe(
      "ye card save kar lo\n📎 card.jpg",
    );
    expect(historyLineForAttachments("", ["rates.pdf"])).toBe("📎 rates.pdf");
  });
});

describe("loadInlineParts", () => {
  it("downloads an owned file into inlineData", async () => {
    downloadMock.mockResolvedValue([Buffer.from("abc")]);
    const loaded = await loadInlineParts("u1", [
      { storagePath: "users/u1/agent_files/card.jpg", mimeType: "image/jpeg", name: "card.jpg" },
    ]);
    expect(loaded.parts).toHaveLength(1);
    expect(loaded.parts[0]!.inlineData.mimeType).toBe("image/jpeg");
    expect(loaded.parts[0]!.inlineData.data).toBe(Buffer.from("abc").toString("base64"));
    expect(loaded.skipped).toEqual([]);
  });

  it("skips a path it does not own rather than downloading it", async () => {
    const loaded = await loadInlineParts("u1", [
      { storagePath: "users/u2/agent_files/card.jpg", mimeType: "image/jpeg", name: "card.jpg" },
    ]);
    expect(loaded.parts).toEqual([]);
    expect(loaded.skipped).toEqual(["card.jpg"]);
    expect(downloadMock).not.toHaveBeenCalled();
  });

  it("skips a file that is too large", async () => {
    downloadMock.mockResolvedValue([Buffer.alloc(9 * 1024 * 1024)]);
    const loaded = await loadInlineParts("u1", [
      { storagePath: "users/u1/agent_files/big.pdf", mimeType: "application/pdf", name: "big.pdf" },
    ]);
    expect(loaded.parts).toEqual([]);
    expect(loaded.skipped).toEqual(["big.pdf"]);
  });
});

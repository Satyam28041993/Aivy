/**
 * Files the user attached on this turn, turned into Gemini inlineData.
 *
 * Callables cannot carry a PDF — the request ceiling is about 10 MB — so the
 * app uploads to Storage and sends only the path. The server downloads that
 * path, and only that path: anything outside `users/{uid}/agent_files/` is
 * refused, including `..` tricks. The bytes go to the model on *this* turn
 * and are never written into chat history; a conversation that replayed
 * base64 would grow until the next turn failed.
 */

import { getStorage } from "firebase-admin/storage";
import { logger } from "firebase-functions";

export const AGENT_FILES_PREFIX = "agent_files";
export const MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024;
export const MAX_ATTACHMENTS = 3;

export const ALLOWED_ATTACHMENT_MIMES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "application/pdf",
]);

export interface FileAttachmentRef {
  storagePath: string;
  mimeType: string;
  name: string;
}

export interface GeminiInlinePart {
  inlineData: { mimeType: string; data: string };
}

export interface LoadedFileParts {
  parts: GeminiInlinePart[];
  skipped: string[];
}

/** Path the server will download, or null if it is not this user's upload. */
export function ownedAgentFilePath(uid: string, raw: string): string | null {
  const path = raw.trim().replace(/^\/+/, "");
  if (!path || path.includes("..") || path.includes("\\")) {
    return null;
  }
  const prefix = `users/${uid}/${AGENT_FILES_PREFIX}/`;
  if (!path.startsWith(prefix)) {
    return null;
  }
  const rest = path.slice(prefix.length);
  if (!rest || rest.split("/").some((s) => !s || s === "." || s === "..")) {
    return null;
  }
  if (!/^[A-Za-z0-9._/-]+$/.test(path)) {
    return null;
  }
  return path;
}

export function normalizeAttachmentMime(raw: string): string | null {
  const mime = raw.trim().toLowerCase();
  if (mime === "image/jpg") {
    return "image/jpeg";
  }
  return ALLOWED_ATTACHMENT_MIMES.has(mime) ? mime : null;
}

export function parseAttachmentRefs(raw: unknown): FileAttachmentRef[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  const out: FileAttachmentRef[] = [];
  for (const item of raw) {
    if (out.length >= MAX_ATTACHMENTS) {
      break;
    }
    if (!item || typeof item !== "object") {
      continue;
    }
    const rec = item as Record<string, unknown>;
    const storagePath = typeof rec.storagePath === "string" ? rec.storagePath.trim() : "";
    const mimeType = typeof rec.mimeType === "string" ? rec.mimeType.trim() : "";
    const name = typeof rec.name === "string" ? rec.name.trim() : "";
    if (!storagePath || !mimeType) {
      continue;
    }
    out.push({
      storagePath,
      mimeType,
      name: name || storagePath.split("/").pop() || "file",
    });
  }
  return out;
}

/** What is stored on the chat row and replayed as history — names, never bytes. */
export function historyLineForAttachments(userText: string, names: string[]): string {
  const body = userText.trim();
  const pins = names
    .map((n) => n.trim())
    .filter(Boolean)
    .map((n) => `📎 ${n}`)
    .join("\n");
  if (body && pins) {
    return `${body}\n${pins}`;
  }
  return pins || body;
}

export async function loadInlineParts(
  uid: string,
  attachments: FileAttachmentRef[],
): Promise<LoadedFileParts> {
  const parts: GeminiInlinePart[] = [];
  const skipped: string[] = [];

  for (const att of attachments.slice(0, MAX_ATTACHMENTS)) {
    const path = ownedAgentFilePath(uid, att.storagePath);
    const mime = normalizeAttachmentMime(att.mimeType);
    if (!path || !mime) {
      skipped.push(att.name);
      continue;
    }
    try {
      const [buf] = await getStorage().bucket().file(path).download();
      if (!buf || buf.length === 0 || buf.length > MAX_ATTACHMENT_BYTES) {
        skipped.push(att.name);
        continue;
      }
      parts.push({
        inlineData: { mimeType: mime, data: buf.toString("base64") },
      });
    } catch (e) {
      logger.warn("fileParts: download failed", {
        uid,
        name: att.name,
        err: e instanceof Error ? e.message : String(e),
      });
      skipped.push(att.name);
    }
  }

  return { parts, skipped };
}

import { createHash } from "node:crypto";

function sanitizeToken(value: string): string {
  return value.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 120);
}

export function historyChunkRecordId(opts: {
  wabaId: string | null;
  phoneNumberId: string | null;
  phase: number | null;
  chunkOrder: number | null;
  chunkIndex: number;
  errorCode: number | null;
}): string {
  const waba = sanitizeToken(opts.wabaId ?? "unknown_waba");
  const phone = sanitizeToken(opts.phoneNumberId ?? "unknown_phone");
  if (opts.errorCode != null && opts.phase == null && opts.chunkOrder == null) {
    return `hist_err_${waba}_${phone}_${opts.errorCode}_${opts.chunkIndex}`;
  }
  const phase = opts.phase ?? -1;
  const order = opts.chunkOrder ?? opts.chunkIndex;
  return `hist_chunk_${waba}_${phone}_p${phase}_c${order}`;
}

export function historySupplementalRecordId(messageId: string): string {
  return `hist_supp_${sanitizeToken(messageId)}`;
}

export function smbSyncRecordId(opts: {
  wabaId: string | null;
  phoneNumber: string;
  action: string;
  timestampSec: number | null;
  syncIndex: number;
}): string {
  const waba = sanitizeToken(opts.wabaId ?? "unknown_waba");
  const phone = sanitizeToken(opts.phoneNumber);
  const action = sanitizeToken(opts.action || "unknown");
  const ts = opts.timestampSec ?? 0;
  return `smb_sync_${waba}_${phone}_${action}_${ts}_${opts.syncIndex}`;
}

export function messageEchoRecordId(messageId: string): string {
  return `echo_${sanitizeToken(messageId)}`;
}

export function hashWebhookPayload(rawBody: unknown): string {
  const serialized =
    typeof rawBody === "string"
      ? rawBody
      : JSON.stringify(rawBody ?? {});
  return createHash("sha256").update(serialized).digest("hex");
}

import { createHmac, timingSafeEqual } from "node:crypto";

export function verifyWebhookQueryToken(
  mode: string,
  verifyToken: string,
  challenge: string,
  expectedToken: string,
): { ok: boolean; challenge: string | null } {
  if (mode !== "subscribe") {
    return { ok: false, challenge: null };
  }
  if (!challenge) {
    return { ok: false, challenge: null };
  }
  return { ok: verifyToken === expectedToken, challenge };
}

export function verifyWebhookSignature(
  rawBody: Buffer,
  signatureHeader: string | undefined,
  appSecret: string,
): boolean {
  if (!signatureHeader) {
    return false;
  }
  const expected = `sha256=${createHmac("sha256", appSecret)
    .update(rawBody)
    .digest("hex")}`;
  const left = Buffer.from(expected);
  const right = Buffer.from(signatureHeader);
  if (left.length !== right.length) {
    return false;
  }
  return timingSafeEqual(left, right);
}

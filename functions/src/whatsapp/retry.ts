import { logger } from "firebase-functions";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function withRetry<T>(
  opName: string,
  fn: () => Promise<T>,
  opts?: { retries?: number; delayMs?: number },
): Promise<T> {
  const retries = opts?.retries ?? 2;
  const delayMs = opts?.delayMs ?? 250;
  let lastError: unknown;
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      if (attempt >= retries) {
        break;
      }
      logger.warn("[whatsapp] retrying operation", {
        opName,
        attempt: attempt + 1,
        retries,
        message: error instanceof Error ? error.message : String(error),
      });
      await sleep(delayMs * (attempt + 1));
    }
  }
  throw lastError;
}

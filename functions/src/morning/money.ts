/**
 * Money out of bank and UPI mail — read by rule, not by the model.
 *
 * The model is good at "what is this email about" and bad at being trusted
 * with a rupee figure: a hallucinated ₹12,000 in a morning brief is worse than
 * no figure at all, because it reads exactly like a real one. So the amounts
 * are extracted here, deterministically and testably, and the model is only
 * ever handed totals it must not change.
 */

export type Direction = "in" | "out";

export interface MoneyLine {
  amount: number;
  direction: Direction;
  /** Whatever the mail called itself, for the user to recognise. */
  source: string;
}

export interface MoneyTotals {
  credited: number;
  spent: number;
  creditCount: number;
  spendCount: number;
  lines: MoneyLine[];
}

// ₹1,234.56 · Rs. 1234 · INR 1,234.00 — the three ways Indian banks write it.
const AMOUNT = /(?:₹|Rs\.?|INR)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)/gi;

const OUT_WORDS =
  /\b(debited|debit|spent|paid|payment of|sent to|withdrawn|purchase|txn of|transferred to)\b/i;
const IN_WORDS = /\b(credited|credit|received|deposited|refund|cashback|added to)\b/i;

export function parseAmount(raw: string): number {
  const n = Number(raw.replace(/,/g, ""));
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/**
 * The direction a single mail describes.
 *
 * When both words appear — "debited ... available balance credited" is common
 * in bank templates — the one that comes first wins, because that is the
 * sentence describing the transaction rather than the balance after it.
 */
export function directionOf(text: string): Direction | null {
  const out = text.search(OUT_WORDS);
  const inn = text.search(IN_WORDS);
  if (out < 0 && inn < 0) {
    return null;
  }
  if (out < 0) {
    return "in";
  }
  if (inn < 0) {
    return "out";
  }
  return out < inn ? "out" : "in";
}

/**
 * One line per mail, not per amount. A bank mail names the transaction and
 * then the running balance; counting both would double the day's spending and
 * invent a credit that never happened.
 */
export function readMoneyMail(mail: { subject: string; snippet: string; from: string }): MoneyLine | null {
  const text = `${mail.subject} ${mail.snippet}`;
  const direction = directionOf(text);
  if (!direction) {
    return null;
  }
  AMOUNT.lastIndex = 0;
  const match = AMOUNT.exec(text);
  if (!match) {
    return null;
  }
  const amount = parseAmount(match[1]!);
  if (amount <= 0) {
    return null;
  }
  return { amount, direction, source: senderLabel(mail.from) };
}

/** "Standard Chartered Bank <alerts@sc.com>" → "Standard Chartered Bank". */
export function senderLabel(from: string): string {
  const named = from.match(/^\s*"?([^"<]+?)"?\s*</);
  if (named && named[1]!.trim()) {
    return named[1]!.trim();
  }
  const addr = from.match(/([\w.+-]+)@/);
  return addr ? addr[1]! : from.trim();
}

export function totalMoney(
  mails: Array<{ subject: string; snippet: string; from: string }>,
): MoneyTotals {
  const lines: MoneyLine[] = [];
  for (const m of mails) {
    const line = readMoneyMail(m);
    if (line) {
      lines.push(line);
    }
  }
  return {
    credited: lines.filter((l) => l.direction === "in").reduce((s, l) => s + l.amount, 0),
    spent: lines.filter((l) => l.direction === "out").reduce((s, l) => s + l.amount, 0),
    creditCount: lines.filter((l) => l.direction === "in").length,
    spendCount: lines.filter((l) => l.direction === "out").length,
    lines,
  };
}

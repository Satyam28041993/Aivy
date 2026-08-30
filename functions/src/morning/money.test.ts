import { describe, expect, it } from "vitest";

import { directionOf, readMoneyMail, senderLabel, totalMoney } from "./money";

function mail(subject: string, snippet = "", from = "alerts@sc.com") {
  return { subject, snippet, from };
}

describe("directionOf", () => {
  it("reads the three ways money leaves", () => {
    expect(directionOf("Your a/c has been debited by INR 500")).toBe("out");
    expect(directionOf("You have paid Rs.200 to Zomato")).toBe("out");
    expect(directionOf("₹150 sent to Ramesh")).toBe("out");
  });

  it("reads money arriving", () => {
    expect(directionOf("INR 25,000.00 credited to your account")).toBe("in");
    expect(directionOf("Refund of Rs.499 processed")).toBe("in");
  });

  it("takes the transaction over the balance line", () => {
    // Bank templates routinely mention both; the first is the event.
    expect(
      directionOf("Rs.500 debited from a/c XX12. Available balance credited as Rs.4,500"),
    ).toBe("out");
  });

  it("says nothing when the mail is not about a transaction", () => {
    expect(directionOf("Your monthly statement is ready")).toBeNull();
  });
});

describe("readMoneyMail", () => {
  it("takes one amount per mail, not every number in it", () => {
    const line = readMoneyMail(
      mail("Debit alert", "Rs.500.00 debited. Available balance INR 4,500.00"),
    );
    // Counting the balance too would report ₹5,000 spent this morning.
    expect(line).toEqual({ amount: 500, direction: "out", source: "alerts" });
  });

  it("handles commas and all three currency spellings", () => {
    expect(readMoneyMail(mail("₹1,25,000 credited"))!.amount).toBe(125000);
    expect(readMoneyMail(mail("INR 2,500.50 debited"))!.amount).toBe(2500.5);
    expect(readMoneyMail(mail("Rs 99 paid"))!.amount).toBe(99);
  });

  it("ignores a mail with no amount, and one with no direction", () => {
    expect(readMoneyMail(mail("Payment debited"))).toBeNull();
    expect(readMoneyMail(mail("Your statement for ₹5,000 is ready"))).toBeNull();
  });
});

describe("senderLabel", () => {
  it("prefers the name a person would recognise", () => {
    expect(senderLabel('"Standard Chartered Bank" <alerts@sc.com>')).toBe(
      "Standard Chartered Bank",
    );
    expect(senderLabel("Google Pay <noreply@google.com>")).toBe("Google Pay");
    expect(senderLabel("upi@axisbank.com")).toBe("upi");
  });
});

describe("totalMoney", () => {
  it("keeps the two directions apart", () => {
    const t = totalMoney([
      mail("Debited", "Rs.500 debited"),
      mail("Debited", "Rs.250.50 debited"),
      mail("Credited", "INR 10,000 credited"),
      mail("Newsletter", "nothing to see"),
    ]);
    expect(t.spent).toBe(750.5);
    expect(t.credited).toBe(10000);
    expect(t.spendCount).toBe(2);
    expect(t.creditCount).toBe(1);
  });

  it("is all zeroes when nothing matched, rather than absent", () => {
    const t = totalMoney([mail("Hello")]);
    expect(t).toMatchObject({ credited: 0, spent: 0, lines: [] });
  });
});

/**
 * The rules in the prompt that were learnt the hard way.
 *
 * A prompt is prose, so nothing stops a later edit from quietly dropping a
 * paragraph. These pin the ones where losing the paragraph reproduces a bug
 * the user already hit, and each test names the failure rather than the words.
 */

import { describe, expect, it } from "vitest";

import { buildSystemPrompt, type PromptContext } from "./systemPrompt";

const CTX: PromptContext = {
  userName: "Satyam",
  timezone: "Asia/Kolkata",
  nowLabel: "Monday, 31 August, 7:19 PM",
  memory: {},
  recentlySaved: [],
  pendingDrafts: [],
  googleConnected: true,
  hasLiveLocation: true,
};

describe("buildSystemPrompt", () => {
  const prompt = buildSystemPrompt(CTX);

  it("tells the model that saved records belong to the person asking", () => {
    // Asked for "mandar sir ka location", the model refused three times on
    // privacy grounds — for an address the user had saved himself. Their own
    // notebook is not somebody else's private data.
    expect(prompt).toContain("Their own records are theirs");
    expect(prompt).toContain("get_saved_place");
    expect(prompt).toMatch(/never refuse it as somebody else's private/i);
  });

  it("keeps the line between reading records back and hunting for someone", () => {
    // The rule must not read as permission to go and find a private person's
    // address that was never recorded.
    expect(prompt).toMatch(/never recorded|not in their notebook/i);
  });

  it("names all three ways a piece of work can be held", () => {
    expect(prompt).toContain("create_task");
    expect(prompt).toContain("create_reminder");
    expect(prompt).toContain("create_project");
  });

  it("still says a write is not done until it is confirmed", () => {
    expect(prompt).toContain("Writes need a yes");
  });

  it("knows they work at Great Eastern IDTech now, not Prakruti", () => {
    // They moved from Prakruti Graphic to Great Eastern IDTech as a BDM on
    // 21 September 2026. Without this, business talk gets filed under the
    // old employer.
    expect(prompt).toContain("Great Eastern IDTech");
    expect(prompt).toContain("21 September 2026");
    expect(prompt).toMatch(/no longer\s+work at Prakruti/);
  });

  it("splits business between Great Eastern and their own PrintSahaj", () => {
    expect(prompt).toContain("PrintSahaj");
    expect(prompt).toMatch(/exactly two things/);
  });

  it("lets the job change overrule an out-of-date remembered employer", () => {
    // Memory written before the move still says Prakruti; a remembered fact
    // cannot overrule itself, so the prompt has to.
    const stale = buildSystemPrompt({
      ...CTX,
      memory: { employer: "Prakruti Graphic Pvt Ltd" },
    });
    expect(stale).toMatch(/that line is\s+out of date/);
    expect(stale.indexOf("# Where they work")).toBeLessThan(
      stale.indexOf("employer: Prakruti Graphic Pvt Ltd"),
    );
  });

  it("does not let it invent Great Eastern facts in front of a client", () => {
    expect(prompt).toMatch(/Never state a Great Eastern specification/);
  });

  it("carries the Great Eastern training material", () => {
    expect(prompt).toContain("Great Eastern IDTech — what you know");
    expect(prompt).toContain("DinoLabelDigital");
    expect(prompt).toContain("Warehouse Management System");
    expect(prompt).toContain("Thermal transfer ribbons");
  });

  it("quotes the current Dino terms, not the older brochure ones", () => {
    // The pitch deck says MOQ 5,000 and 5-7 days; the cheat sheet and the
    // quotation format say Rs 10,000 MOV and 7 working days. Left to
    // itself the model picks one at random in front of a client.
    expect(prompt).toContain("Minimum order value ₹10,000 per order");
    expect(prompt).toContain("Lead time: 7 working days");
    expect(prompt).toMatch(/Do not quote those/);
  });

  it("prices come from the price book, never from memory", () => {
    expect(prompt).toContain("call `get_price` before giving any");
    expect(prompt).toMatch(/Never price from memory/);
    expect(prompt).toContain("GST extra");
    // The user said the prices are for their eyes; they must not leak into
    // something sent to a client unasked.
    expect(prompt).toMatch(/do not put a price into an\s+email/);
    // The multiplier is the cross-check the user asked for.
    expect(prompt).toMatch(/check it equals chrome x multiplier/);
  });

  it("knows BarTender: editions, licensing and the Starter printer question", () => {
    expect(prompt).toContain("BarTender — label design and printing software");
    // Workstation licence = one PC, unlimited printers; the old "up to 3"
    // was the printer-based Starter. The price book sells the workstation one.
    expect(prompt).toMatch(/workstation licence\*\* is one user on one PC with \*\*unlimited printers/);
    expect(prompt).toContain("Say unlimited printers, one PC.");
    expect(prompt).not.toContain("Starter (up to 3 printers)");
    // Each edition and the cloud plans are covered.
    for (const s of ["*Professional adds*", "*Automation adds*", "*Enterprise adds*", "BarTender Cloud plans"]) {
      expect(prompt).toContain(s);
    }
    // No website dollar prices: Great Eastern's prices come from get_price.
    expect(prompt).not.toMatch(/\$\s?\d/);
  });

  it("runs the DSR the way the user asked: ask once, confirm, then offer a follow-up", () => {
    expect(prompt).toContain("record_visit");
    expect(prompt).toMatch(/ask for all of it in one short\s+message/);
    expect(prompt).toMatch(/ask whether to set a follow-up/);
    expect(prompt).toContain("set_visit_followup");
    expect(prompt).toContain("list_visits");
  });

  it("knows how to recommend, and hands over the brochure", () => {
    expect(prompt).toContain("Recommending a product");
    expect(prompt).toContain("find_document");
    expect(prompt).toContain("Product catalogue (from the brochures)");
    // Specs must come from the brochure text, not the one-line catalogue.
    expect(prompt).toContain("read_document");
    expect(prompt).toContain("Specifications come from the brochure");
  });

  it("looks things up on the company website rather than guessing", () => {
    expect(prompt).toContain("site:geipl.com");
    expect(prompt).toContain("site:dinolabeldigital.com");
  });
});

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

  it("will not quote a price before it has the price list", () => {
    expect(prompt).toMatch(/Never quote a price, discount or rate/);
  });

  it("looks things up on the company website rather than guessing", () => {
    expect(prompt).toContain("site:geipl.com");
    expect(prompt).toContain("site:dinolabeldigital.com");
  });
});

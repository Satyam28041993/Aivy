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
});

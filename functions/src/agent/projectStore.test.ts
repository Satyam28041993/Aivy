import { describe, expect, it } from "vitest";

import { summarise, type Project, type ProjectItem } from "./projectStore";

const NOW = Date.parse("2026-09-10T09:00:00+05:30");
const DAY = 24 * 60 * 60 * 1000;

const project: Project = {
  id: "p1",
  name: "Pune label project",
  nameKey: "pune label project",
  clientName: "Sharma Packaging",
  status: "active",
  note: "",
  createdAtMs: 0,
  updatedAtMs: 0,
};

function item(part: Partial<ProjectItem>): ProjectItem {
  return {
    id: Math.random().toString(36).slice(2),
    projectId: "p1",
    title: "something",
    kind: "task",
    status: "open",
    dueMs: 0,
    note: "",
    reminderId: "",
    createdAtMs: 0,
    updatedAtMs: 0,
    ...part,
  };
}

describe("summarise", () => {
  it("keeps what he owes apart from what they owe", () => {
    // The whole point of the third status: waiting on a client is not the same
    // as being behind, and folding them together makes both answers useless.
    const s = summarise(
      project,
      [
        item({ title: "send samples", status: "done" }),
        item({ title: "finalise rate", status: "open" }),
        item({ title: "feature approval", status: "waiting_on_them" }),
        item({ title: "PO", status: "waiting_on_them" }),
      ],
      NOW,
    );
    expect(s.done.map((i) => i.title)).toEqual(["send samples"]);
    expect(s.open.map((i) => i.title)).toEqual(["finalise rate"]);
    expect(s.waiting.map((i) => i.title)).toEqual(["feature approval", "PO"]);
  });

  it("counts a client's overdue item as overdue too", () => {
    // An approval that was promised last week is late whoever it is with.
    const s = summarise(
      project,
      [
        item({ title: "rate", status: "open", dueMs: NOW - DAY }),
        item({ title: "approval", status: "waiting_on_them", dueMs: NOW - 3 * DAY }),
        item({ title: "delivery", status: "open", dueMs: NOW + DAY }),
      ],
      NOW,
    );
    expect(s.overdue.map((i) => i.title).sort()).toEqual(["approval", "rate"]);
  });

  it("never counts a finished or dropped item as late", () => {
    const s = summarise(
      project,
      [
        item({ title: "old sample", status: "done", dueMs: NOW - 10 * DAY }),
        item({ title: "cancelled", status: "dropped", dueMs: NOW - 10 * DAY }),
      ],
      NOW,
    );
    expect(s.overdue).toEqual([]);
  });

  it("picks the soonest live dated item as what is next", () => {
    const s = summarise(
      project,
      [
        item({ title: "later", status: "open", dueMs: NOW + 5 * DAY }),
        item({ title: "sooner", status: "waiting_on_them", dueMs: NOW + DAY }),
        item({ title: "no date", status: "open" }),
        item({ title: "done sooner still", status: "done", dueMs: NOW }),
      ],
      NOW,
    );
    expect(s.next?.title).toBe("sooner");
  });

  it("has no next when nothing live carries a date", () => {
    const s = summarise(project, [item({ title: "someday", status: "open" })], NOW);
    expect(s.next).toBeNull();
  });
});

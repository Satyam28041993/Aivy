import type {
  ProjectItemRecord,
  ProjectItemStatus,
  ProjectRecord,
  ProjectSummaryBuckets,
} from "./types";

export function bucketItems(items: ProjectItemRecord[]): ProjectSummaryBuckets {
  const buckets: ProjectSummaryBuckets = {
    pending: [],
    waitingOnThem: [],
    done: [],
    cancelled: [],
  };
  for (const item of items) {
    switch (item.status) {
      case "waiting_on_them":
        buckets.waitingOnThem.push(item);
        break;
      case "done":
        buckets.done.push(item);
        break;
      case "cancelled":
        buckets.cancelled.push(item);
        break;
      default:
        buckets.pending.push(item);
        break;
    }
  }
  return buckets;
}

function lineFor(item: ProjectItemRecord): string {
  const bits = [`• ${item.title}`];
  if (item.kind !== "general") {
    bits.push(`(${item.kind})`);
  }
  if (item.waitingOn) {
    bits.push(`— waiting: ${item.waitingOn}`);
  }
  if (item.dueAtMs) {
    const d = new Date(item.dueAtMs);
    bits.push(`— ${d.toLocaleDateString("en-IN", { day: "numeric", month: "short" })}`);
  }
  return bits.join(" ");
}

export function formatProjectSummaryHinglish(
  project: ProjectRecord,
  items: ProjectItemRecord[],
): string {
  const b = bucketItems(items);
  const open = b.pending.length + b.waitingOnThem.length;
  const lines = [
    `${project.name}${project.client && project.client !== project.name ? ` · ${project.client}` : ""}`,
    `Status: ${project.status} · ${open} open, ${b.done.length} done`,
  ];
  if (b.waitingOnThem.length) {
    lines.push("", "Waiting on them:");
    for (const i of b.waitingOnThem) {
      lines.push(lineFor(i));
    }
  }
  if (b.pending.length) {
    lines.push("", "Pending (aapke side):");
    for (const i of b.pending) {
      lines.push(lineFor(i));
    }
  }
  if (b.done.length) {
    lines.push("", `Done: ${b.done.length}`);
  }
  if (open === 0 && b.done.length === 0 && b.cancelled.length === 0) {
    lines.push("", "Abhi koi item nahi hai — chat mein notes bhejo.");
  } else if (open === 0) {
    lines.push("", "Kuch atka nahi — saaf hai.");
  }
  return lines.join("\n");
}

export function formatTodayItemsHinglish(
  items: Array<ProjectItemRecord & { projectName?: string }>,
): string {
  if (items.length === 0) {
    return "Aaj koi project item due nahi · waiting on them bhi empty.";
  }
  const waiting = items.filter((i) => i.status === "waiting_on_them");
  const pending = items.filter((i) => i.status === "pending");
  const lines = [`Aaj ke project items (${items.length}):`];
  if (waiting.length) {
    lines.push("", "Waiting on them:");
    for (const i of waiting) {
      lines.push(`${lineFor(i)}${i.projectName ? ` · ${i.projectName}` : ""}`);
    }
  }
  if (pending.length) {
    lines.push("", "Aapke pending:");
    for (const i of pending) {
      lines.push(`${lineFor(i)}${i.projectName ? ` · ${i.projectName}` : ""}`);
    }
  }
  return lines.join("\n");
}

export function nextActionLine(items: ProjectItemRecord[]): string {
  const waiting = items.filter((i) => i.status === "waiting_on_them");
  const pending = items.filter((i) => i.status === "pending");
  if (waiting.length) {
    const first = waiting[0]!;
    const who = first.waitingOn || "client";
    return `Next: ${who} se ${first.title} nikalwana.`;
  }
  if (pending.length) {
    return `Next: ${pending[0]!.title}`;
  }
  return "Next: kuch open nahi.";
}

export function statusLabelHinglish(status: ProjectItemStatus): string {
  switch (status) {
    case "waiting_on_them":
      return "waiting on them";
    case "done":
      return "done";
    case "cancelled":
      return "cancelled";
    default:
      return "pending";
  }
}

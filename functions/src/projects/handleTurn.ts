import { detectProjectTurn, extractProjectNameHint } from "./detect";
import { extractDraftWithGemini } from "./geminiExtract";
import {
  formatProjectSummaryHinglish,
  formatTodayItemsHinglish,
  nextActionLine,
  statusLabelHinglish,
} from "./summary";
import {
  findProjectByHint,
  listItemsForProject,
  listOpenItems,
  listProjects,
  listTodayItems,
  matchItemByText,
  updateItemStatus,
} from "./store";
import type {
  ProjectClock,
  ProjectItemStatus,
  ProjectTurnResult,
} from "./types";

function formatExtractCard(draft: ProjectTurnResult["projectDraft"]): string {
  if (!draft) {
    return "Project items nikaale — Confirm dabao.";
  }
  const lines = [
    `Project: ${draft.projectName}${draft.client ? ` · ${draft.client}` : ""}`,
    "",
  ];
  draft.items.forEach((item, i) => {
    const status =
      item.status === "waiting_on_them" ? "waiting on them" : item.status;
    const due = item.dueLabel ? ` · ${item.dueLabel}` : "";
    const who = item.waitingOn ? ` · ${item.waitingOn}` : "";
    lines.push(`${i + 1}. [${item.kind}] ${item.title} — ${status}${due}${who}`);
  });
  lines.push("", "Confirm / Edit / Cancel — save se pehle theek kar lo.");
  return lines.join("\n");
}

function inferUpdateStatus(text: string): ProjectItemStatus | null {
  const t = text.toLowerCase();
  if (/\b(cancel|cancelled|chhod|drop)\b/.test(t)) {
    return "cancelled";
  }
  if (/\b(waiting|unpe atka|un par|client pe)\b/.test(t)) {
    return "waiting_on_them";
  }
  if (/\b(done|ho gaya|ho gya|complete|khatam|finish)\b/.test(t)) {
    return "done";
  }
  if (/\b(pending|open|wapas pending)\b/.test(t)) {
    return "pending";
  }
  return null;
}

export async function tryHandleProjectTurn(opts: {
  uid: string;
  text: string;
  clock: ProjectClock;
  geminiKey: string;
}): Promise<ProjectTurnResult | null> {
  const turn = detectProjectTurn(opts.text);
  if (!turn) {
    return null;
  }

  if (turn === "dump") {
    const draft = await extractDraftWithGemini({
      text: opts.text,
      clock: opts.clock,
      geminiKey: opts.geminiKey,
    });
    const hint = extractProjectNameHint(opts.text) || draft.projectName;
    const existing = hint ? await findProjectByHint(opts.uid, hint) : null;
    if (existing) {
      draft.projectId = existing.id;
      draft.projectName = existing.name;
      if (!draft.client) {
        draft.client = existing.client;
      }
    }
    return {
      mode: "extract",
      userReply: formatExtractCard(draft),
      projectDraft: draft,
      data: {
        analyticsKind: "project_extract",
        projectDraft: true,
        flowCategoryId: "project_items",
        projectName: draft.projectName,
        client: draft.client,
        items: draft.items,
      },
    };
  }

  if (turn === "today") {
    const items = await listTodayItems(opts.uid, opts.clock);
    return {
      mode: "today",
      userReply: formatTodayItemsHinglish(items),
      data: {
        analyticsKind: "project_today",
        count: items.length,
        rows: items.map((i) => ({
          client: i.projectName,
          title: i.title,
          status: i.status,
          dueMs: i.dueAtMs ?? undefined,
        })),
      },
    };
  }

  if (turn === "query") {
    const hint = extractProjectNameHint(opts.text);
    if (!hint) {
      const projects = await listProjects(opts.uid);
      const open = await listOpenItems(opts.uid);
      if (projects.length === 0) {
        return {
          mode: "query",
          userReply:
            "Abhi koi project save nahi hai. Notes bhejo — main items nikaal ke confirm card dunga.",
        };
      }
      const waiting = open.filter((i) => i.status === "waiting_on_them").length;
      const pending = open.filter((i) => i.status === "pending").length;
      const lines = [
        `${projects.length} projects · ${pending} pending · ${waiting} waiting on them`,
        "",
      ];
      for (const p of projects.slice(0, 8)) {
        lines.push(`• ${p.name}${p.status !== "active" ? ` (${p.status})` : ""}`);
      }
      lines.push("", "Naam ke saath poocho: “Pune project ka kya haal hai”.");
      return { mode: "query", userReply: lines.join("\n") };
    }
    const project = await findProjectByHint(opts.uid, hint);
    if (!project) {
      return {
        mode: "query",
        userReply: `"${hint}" naam ka project nahi mila. Pehle notes bhej ke save karo.`,
      };
    }
    const items = await listItemsForProject(opts.uid, project.id);
    const body = formatProjectSummaryHinglish(project, items);
    const next = nextActionLine(items);
    return {
      mode: "query",
      userReply: `${body}\n\n${next}`,
      data: {
        analyticsKind: "project_summary",
        projectId: project.id,
        projectName: project.name,
      },
    };
  }

  // update
  const status = inferUpdateStatus(opts.text);
  const hint = extractProjectNameHint(opts.text);
  const open = hint
    ? await (async () => {
        const p = await findProjectByHint(opts.uid, hint);
        return p ? listItemsForProject(opts.uid, p.id) : listOpenItems(opts.uid);
      })()
    : await listOpenItems(opts.uid);
  const matches = matchItemByText(open, opts.text);
  if (!status) {
    return {
      mode: "update",
      userReply: "Status clear nahi — done / waiting on them / cancel likho.",
    };
  }
  if (matches.length === 0) {
    return {
      mode: "update",
      userReply: "Kaunsa item? Project ya item ka naam ke saath likho.",
    };
  }
  if (matches.length > 1) {
    const list = matches
      .slice(0, 6)
      .map((m, i) => `${i + 1}. ${m.title} (${m.projectName})`)
      .join("\n");
    return {
      mode: "update",
      userReply: `Kai items mile. Number ya exact title bhejo:\n${list}`,
    };
  }
  const item = matches[0]!;
  const updated = await updateItemStatus(opts.uid, item.id, status);
  const label = statusLabelHinglish(status);
  return {
    mode: "update",
    userReply: updated
      ? `${updated.projectName} → ${updated.title}: ${label}.`
      : "Update nahi ho paya — dubara try karo.",
  };
}

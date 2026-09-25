/**
 * Visiting cards and the document library.
 *
 * Writes stop at a draft, same as every other write tool. The model extracts
 * the fields; this file only checks they are present and draws the card.
 * Search answers immediately — a lookup is not a write.
 */

import { createDraft } from "../draftStore";
import {
  findContactByPhone,
  normalizeIndiaPhone,
} from "../contactStore";
import {
  findLibraryByTitleKind,
  isLibraryKind,
  searchLibrary,
  type LibraryFact,
  type LibraryKind,
} from "../libraryStore";
import type { DraftCardLine } from "../draftTypes";
import { dataResult, draftResult, fail, type ToolContext, type ToolResult } from "../toolTypes";

function str(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

function factsFrom(raw: unknown): LibraryFact[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  const out: LibraryFact[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") {
      continue;
    }
    const rec = item as Record<string, unknown>;
    const label = str(rec.label) || str(rec.key);
    const value = str(rec.value);
    if (label && value) {
      out.push({ label, value });
    }
  }
  return out;
}

function kindOf(raw: unknown): LibraryKind {
  const v = str(raw).toLowerCase().replace(/\s+/g, "_");
  if (v === "ratecard") {
    return "rate_card";
  }
  return isLibraryKind(v) ? v : "other";
}

// ---------------------------------------------------------------------------
// save_contact
// ---------------------------------------------------------------------------

export async function saveContactTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const name = str(args.name);
  if (!name) {
    return fail("needs_detail", "What is their name? I need at least that to save a contact.");
  }
  const phoneRaw = str(args.phone);
  const phone = normalizeIndiaPhone(phoneRaw) ?? "";
  if (phoneRaw && !phone) {
    return fail(
      "needs_detail",
      `"${phoneRaw}" does not look like a phone number — 10 digits, or 91 plus 10.`,
    );
  }
  const email = str(args.email);
  const company = str(args.company);
  const notes = str(args.notes);
  if (!phone && !email) {
    return fail(
      "needs_detail",
      "I need a phone number or an email to save this contact — which one is on the card?",
    );
  }

  const existing = phone ? await findContactByPhone(ctx.uid, phone) : null;

  const lines: DraftCardLine[] = [{ label: "Name", value: name }];
  if (company) {
    lines.push({ label: "Company", value: company });
  }
  if (phone) {
    lines.push({ label: "Phone", value: phone });
  }
  if (email) {
    lines.push({ label: "Email", value: email });
  }
  if (notes) {
    lines.push({ label: "Notes", value: notes });
  }
  if (existing) {
    lines.push({ label: "Note", value: "Already saved — this will update it." });
  }

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "saved_contact",
    title: existing ? "Update contact" : "Save contact",
    icon: "🪪",
    lines,
    chatId: ctx.chatId,
    data: {
      kind: "saved_contact",
      name,
      phone,
      company,
      email,
      notes,
      replacing: existing != null,
      existingId: existing?.id ?? null,
    },
  });

  return draftResult(
    draft,
    existing
      ? "This number is already saved — the card updates it. Ask them to confirm."
      : "Ready to save this contact — ask them to confirm.",
  );
}

// ---------------------------------------------------------------------------
// save_library_item
// ---------------------------------------------------------------------------

export async function saveLibraryItemTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const title = str(args.title);
  if (!title) {
    return fail("needs_detail", "What should I call this document?");
  }
  const kind = kindOf(args.kind);
  const excerpt = str(args.excerpt);
  const facts = factsFrom(args.facts);
  if (!excerpt && facts.length === 0) {
    return fail(
      "needs_detail",
      "I need at least a short excerpt or one fact from the document, or there will be nothing to search later.",
    );
  }

  const existing = await findLibraryByTitleKind(ctx.uid, title, kind);
  const sourceName = str(args.source_name);
  const mimeType = str(args.mime_type);
  const storagePath = str(args.storage_path);

  const lines: DraftCardLine[] = [
    { label: "Title", value: title },
    { label: "Kind", value: kind.replace(/_/g, " ") },
  ];
  if (sourceName) {
    lines.push({ label: "File", value: sourceName });
  }
  if (excerpt) {
    lines.push({
      label: "Excerpt",
      value: excerpt.length > 160 ? `${excerpt.slice(0, 157)}…` : excerpt,
    });
  }
  for (const f of facts.slice(0, 8)) {
    lines.push({ label: f.label, value: f.value });
  }
  if (facts.length > 8) {
    lines.push({ label: "More", value: `${facts.length - 8} more fact(s)` });
  }
  if (existing) {
    lines.push({ label: "Note", value: "Same title already filed — this will replace it." });
  }

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "library_item",
    title: existing ? "Update library" : "File this",
    icon: "📄",
    lines,
    chatId: ctx.chatId,
    data: {
      kind: "library_item",
      title,
      libraryKind: kind,
      sourceName,
      mimeType,
      storagePath,
      excerpt,
      facts,
      replacing: existing != null,
      existingId: existing?.id ?? null,
    },
  });

  return draftResult(
    draft,
    "Ready to file this in their library — ask them to confirm.",
  );
}

// ---------------------------------------------------------------------------
// search_library
// ---------------------------------------------------------------------------

export async function searchLibraryTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const query = str(args.query);
  if (!query) {
    return fail("needs_detail", "What should I look up in the library?");
  }
  const rows = await searchLibrary(ctx.uid, query, 8);
  if (rows.length === 0) {
    return fail(
      "nothing_found",
      `Nothing in the library matches "${query}". If they have the file, they can attach it and I will file it.`,
    );
  }
  return dataResult({
    count: rows.length,
    items: rows.map((r) => ({
      title: r.title,
      kind: r.kind,
      excerpt: r.excerpt,
      facts: r.facts,
      source_name: r.sourceName,
    })),
  });
}

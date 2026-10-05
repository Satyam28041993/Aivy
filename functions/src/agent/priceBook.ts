/**
 * Great Eastern's price book, for the user's own eyes.
 *
 * The prices live in Firestore `priceBook/current`, written from the user's
 * Google Sheet by `scripts/syncPriceBook.cjs` — never in this repository,
 * which is public. The sheet is the transcription of the printed book that the
 * user checks; a correction there reaches Aivy on the next sync.
 *
 * `get_price` hands the model the matching rows as the book has them, plus the
 * numbers it needs to say them right: labels per roll, the Indian Chrome rate
 * per 1000, every other material's rate with its multiplier, the ribbon roll
 * price worked out from the per-square-metre rate. The model should not do
 * arithmetic a tool can do, and should not quote a number the book does not
 * have.
 */

import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";

import { dataResult, fail, type ToolContext, type ToolResult } from "./toolTypes";

export const PRICE_COLLECTION = "priceBook";
export const PRICE_DOC = "current";

export interface SystemRow {
  page: number | null;
  category: string;
  brand: string;
  model: string;
  description: string;
  price: number | null;
  price_text: string;
  unit: string;
  item: string;
  brochure: string;
  brochure_link: string;
  brochure_note: string;
  brand_note: string;
}

export interface LabelRow {
  sno: number | null;
  size: string;
  ups: number | null;
  note: string;
  per_roll: Record<string, number | null>;
  base_rate: number | null;
  rates: Record<string, number>;
  flag: string;
}

export interface LabelTable {
  title: string;
  base_label: string;
  multipliers: Record<string, number | null>;
  rows: LabelRow[];
}

export interface PriceBook {
  terms: Array<{ section: string; term: string }>;
  systems: SystemRow[];
  labels: Record<string, LabelTable>;
  supply_notes: string[];
  wristbands: Array<{ section: string; type: string; model: string; pack: string; price_pack: number | null; price_band: number | null }>;
  tapes: Array<{ section: string; size: string; price_roll: number | null }>;
  ribbons: {
    note: string;
    per_sqm: Array<{ sno: number | null; group: string; type: string; per_sqm: number | null }>;
    structure: Array<{ printer: string; core_id: string; core_length: string; widths: string; lengths: string }>;
  };
  printheads: { note: string; rows: Array<{ group: string; model: string; dpi: number | null; price: number | null }> };
  multipliers: {
    note: string;
    rows: Array<{ group: string; material: string; multiplier: number | null; multiplier_text: string; applied_to: string; note: string }>;
  };
  no_brochure: Array<{ status: string; category: string; brand: string; model: string; why: string }>;
  doubts: Array<{ type: string; point: string }>;
  sheetModifiedTime?: string;
  syncedAtMs?: number;
}

/** Said with every answer, because a price without them is a wrong price. */
export const PRICE_BASICS = [
  "Recommended Selling Price (RSP) in Rs. GST extra, freight extra, ex-works. The book's prices are fixed: no extra discount; special, government or project prices need senior management's written approval.",
];

const LABEL_BASICS =
  "Label rates are per 1000 pcs, plain, permanent adhesive. Each material's rate = the Indian Chrome rate x the multiplier in its name. Custom printing is charged on top of the material rate (see the custom printed rate and the terms for its MOQ). Ribbon is quoted separately.";

function compact(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, "");
}

function words(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9.]+/g, " ")
    .split(" ")
    .filter((w) => w.length > 0);
}

const STOP = new Set([
  "the", "a", "an", "of", "for", "and", "or", "ka", "ki", "ke", "ko", "do", "de", "kya", "hai",
  "price", "prices", "rate", "rates", "cost", "kitna", "kitne", "kitni", "batao", "bata", "rs",
  "rupees", "me", "mujhe", "please", "wala", "waala", "chahiye", "the", "with", "per", "list",
]);

/** "50x50", "50 X 50 mm", "50*50" → "50X50". Also 1" x 2" tags → "1X2". */
export function sizeKeys(query: string): string[] {
  const out: string[] = [];
  const re = /(\d+(?:\.\d+)?)\s*(?:mm|"|”|inch|in)?\s*[x×*]\s*(\d+(?:\.\d+)?)/gi;
  for (const m of query.matchAll(re)) out.push(`${m[1]}X${m[2]}`);
  const round = /(\d+)\s*mm\s*round|round\s*(\d+)\s*mm/i.exec(query);
  if (round) out.push(`${round[1] ?? round[2]}MMROUND`);
  return out;
}

function rowSizeKey(size: string): string {
  return size.toUpperCase().replace(/["”\s]/g, "").replace(/^(\d+)MMROUND$/, "$1MMROUND");
}

/** Keeps the rates whose name matches the material asked for, or all of them. */
export function pickRates(rates: Record<string, number>, material: string): Record<string, number> {
  const m = material.trim().toLowerCase();
  if (!m) return rates;
  const want = words(m).filter((w) => !STOP.has(w));
  const synonyms: Record<string, string[]> = {
    pp: ["pp"], polypropylene: ["pp"], bopp: ["pp"], polyester: ["polyester"], pet: ["polyester"],
    tt: ["thermal transfer"], dt: ["dt paper"], "direct": ["dt paper"], chrome: ["chrome"],
    void: ["void"], tamper: ["tte"], tte: ["tte"], udv: ["udv"], tyre: ["tyre"], tire: ["tyre"],
    custom: ["custom"], printed: ["custom"], removable: ["removable"], piggyback: ["piggyback"],
    silver: ["silver"], white: ["white"], clear: ["clear"], transparent: ["clear"],
    drum: ["drum"], cryogenic: ["cryogenic"], ul: ["ul"], eco: ["eco"], synthetic: ["synthetic"],
  };
  const out: Record<string, number> = {};
  for (const [name, v] of Object.entries(rates)) {
    // Match on the material's own name, not the "(2.00 x Chrome)" every heading carries.
    const n = name.toLowerCase().replace(/\(\d[\d.]* x [^)]*\)/g, "");
    const hit = want.every((w) => (synonyms[w] ?? [w]).some((s) => new RegExp(`(^|[^a-z])${s}([^a-z]|$)`).test(n)));
    if (hit) out[name] = v;
  }
  return Object.keys(out).length ? out : rates;
}

function scoreSystem(row: SystemRow, query: string): number {
  const hay = `${row.model} ${row.brand} ${row.category} ${row.description}`;
  const hayWords = new Set(words(hay));
  const modelCompact = compact(row.model);
  let score = 0;
  for (const w of words(query)) {
    if (STOP.has(w)) continue;
    if (/\d/.test(w) && w.length >= 3 && modelCompact.includes(compact(w))) score += 5;
    else if (hayWords.has(w)) score += 1;
  }
  const q = compact(query);
  if (q.length >= 4 && /\d/.test(q) && modelCompact.includes(q)) score += 5;
  return score;
}

function has(query: string, re: RegExp): boolean {
  return re.test(query.toLowerCase());
}

/** Roll price for a ribbon: width mm x length m / 1000 x rate per sq m. */
export function ribbonRollPrice(perSqm: number, widthMm: number, lengthM: number): number {
  return Math.round(((perSqm * widthMm * lengthM) / 1000) * 100) / 100;
}

/** Pure lookup over a loaded book, so it can be tested without Firestore. */
export function lookupPrice(book: PriceBook, query: string, material = ""): Record<string, unknown> | null {
  const out: Record<string, unknown> = {};
  const q = query.trim();

  // Labels and tags by size.
  const keys = sizeKeys(q);
  if (keys.length) {
    const wantTags = has(q, /\btags?\b/);
    const found: Array<Record<string, unknown>> = [];
    const swapped: Array<Record<string, unknown>> = [];
    for (const [table, t] of Object.entries(book.labels)) {
      if (table === "tags" && !wantTags && !has(q, /"|inch/)) continue;
      for (const r of t.rows) {
        const k = rowSizeKey(r.size);
        const hit = keys.includes(k);
        const rev = keys.some((key) => {
          const m = /^(\d+(?:\.\d+)?)X(\d+(?:\.\d+)?)$/.exec(key);
          return m ? k === `${m[2]}X${m[1]}` : false;
        });
        if (!hit && !rev) continue;
        const entry = {
          table: t.title,
          size_w_x_h: r.size,
          ups: r.ups,
          note: r.note,
          labels_per_roll: r.per_roll,
          [t.base_label]: r.base_rate,
          rates_per_1000: pickRates(r.rates, material),
          ...(r.flag ? { check: r.flag } : {}),
        };
        (hit ? found : swapped).push(entry);
      }
    }
    if (found.length) out.labels = found;
    // The other orientation only when the asked one is not in the book.
    if (!found.length && swapped.length) {
      out.labels_other_orientation = swapped;
      out.orientation_note =
        "These rows have width and height the other way round (the book lists W x H). Confirm which way the label runs before quoting.";
    }
    if (out.labels || out.labels_other_orientation) out.label_basics = LABEL_BASICS;
  }

  // Ribbons.
  if (has(q, /ribbon|\bttr\b|\btto\b|\bwax\b|resin/)) {
    const width = /(\d{2,3})\s*mm/i.exec(q);
    const length = /(\d{2,3})\s*(?:m|mtr|mtrs|meter|metre|meters|metres)\b/i.exec(q);
    const rows = book.ribbons.per_sqm.map((r) => {
      const row: Record<string, unknown> = { type: r.type, group: r.group, rs_per_sqm: r.per_sqm };
      if (width && length && r.per_sqm !== null) {
        row[`roll_${width[1]}mm_x_${length[1]}m`] = ribbonRollPrice(r.per_sqm, Number(width[1]), Number(length[1]));
      }
      return row;
    });
    const wanted = rows.filter((r) => words(String(r.type)).some((w) => w.length > 2 && words(q).includes(w)));
    out.ribbons = wanted.length ? wanted : rows;
    out.ribbon_basics =
      "Ribbon price is per square metre, black only: roll price = width (mm) x length (m) / 1000 x rate. Standard widths 35, 44, 55, 65, 80, 85, 110 mm; lengths 100, 200, 300, 600 m. Ask for the printer make and model - the core differs by printer.";
    if (!(width && length)) out.ribbon_hint = "Give a width in mm and a length in m to get the roll price.";
    out.ribbon_cores = book.ribbons.structure;
  }

  // Printheads.
  if (has(q, /head/)) {
    const rows = book.printheads.rows.filter((r) => {
      const m = compact(r.model);
      return words(q).some((w) => /\d/.test(w) && w.length >= 3 && m.includes(compact(w)));
    });
    out.printheads = rows.length ? rows : book.printheads.rows;
    out.printhead_note = book.printheads.note;
  }

  // Wrist bands and tapes.
  if (has(q, /wrist|band/)) out.wristbands = book.wristbands;
  if (has(q, /tape|taffeta|fabric|heat.?seal|nylon/)) out.tapes = book.tapes;

  // Terms: warranty, payment, MOQ, lead time, returns.
  if (has(q, /term|warrant|payment|credit|advance|moq|mov|minimum|lead.?time|delivery|return|rma|gst|freight|discount|install|plate|die\b|e-?waste/)) {
    const qs = words(q).filter((w) => !STOP.has(w) && w.length > 2);
    const hits = book.terms.filter((t) => qs.some((w) => `${t.section} ${t.term}`.toLowerCase().includes(w.replace(/s$/, ""))));
    out.terms = hits.length ? hits : book.terms;
  }
  // Systems by model, brand or kind.
  if (!out.labels && !out.printheads) {
    const scored = book.systems
      .map((r) => ({ r, s: scoreSystem(r, q) }))
      .filter((x) => x.s > 0)
      .sort((a, b) => b.s - a.s);
    // A terms question ("MOQ for labels") is not a product search unless it
    // names a model number.
    if (scored.length && (!out.terms || scored[0].s >= 5)) {
      const top = scored[0].s;
      // A model number hit is decisive; keep its accessories, drop the noise.
      const keep = scored.filter((x) => (top >= 5 ? x.s >= 5 : x.s >= top)).slice(0, 12);
      out.systems = keep.map(({ r }) => ({
        model: r.model,
        brand: r.brand,
        category: r.category,
        description: r.description,
        price: r.price ?? r.price_text,
        unit: r.unit,
        item: r.item,
        brochure: r.brochure,
        ...(r.brochure_link ? { brochure_link: r.brochure_link } : {}),
        ...(r.brochure_note ? { brochure_note: r.brochure_note } : {}),
        ...(r.brand_note ? { brand_note: r.brand_note } : {}),
      }));
    }
  }

  if (has(q, /multiplier|material list|all materials/)) out.multipliers = book.multipliers;

  if (Object.keys(out).length === 0) return null;
  return { query: q, ...(material ? { material } : {}), basics: PRICE_BASICS, ...out };
}

let cache: { book: PriceBook; at: number } | null = null;
const CACHE_MS = 5 * 60 * 1000;

async function loadBook(): Promise<PriceBook | null> {
  if (cache && Date.now() - cache.at < CACHE_MS) return cache.book;
  const snap = await getFirestore().collection(PRICE_COLLECTION).doc(PRICE_DOC).get();
  const data = snap.data() as PriceBook | undefined;
  if (!data || !Array.isArray(data.systems)) return null;
  cache = { book: data, at: Date.now() };
  return data;
}

/** For tests. */
export function clearPriceCache(): void {
  cache = null;
}

export async function getPriceTool(_ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const query = typeof args.query === "string" ? args.query.trim() : "";
  const material = typeof args.material === "string" ? args.material.trim() : "";
  if (!query) return fail("needs_detail", "Which product, label size, ribbon or term do they want the price for?");
  let book: PriceBook | null;
  try {
    book = await loadBook();
  } catch (e) {
    logger.warn("get_price: read failed", { err: e instanceof Error ? e.message : String(e) });
    return fail("failed", "I couldn't open the price book just now.");
  }
  if (!book) {
    return fail(
      "nothing_found",
      "The price book has not been synced from the Google Sheet yet (Sync Document Library workflow).",
    );
  }
  const result = lookupPrice(book, query, material);
  if (!result) {
    return fail(
      "nothing_found",
      `"${query}" is not in the Great Eastern price book. Try a model number (BX410T, DS2208), a label size with material (50x50 PP white), a ribbon (wax 110mm 300m), a printhead, wrist bands, tapes, or a term (warranty, payment, MOQ).`,
    );
  }
  return dataResult(result);
}

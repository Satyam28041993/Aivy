/**
 * Copies the Great Eastern price book from the user's Google Sheet into
 * Firestore `priceBook/current`, where Aivy's `get_price` tool reads it
 * (functions/src/agent/priceBook.ts).
 *
 * The prices are not in this repository on purpose: the repo is public, the
 * price book is internal. The sheet is the source of truth — the user checks
 * it against the printed book and corrects it there — and this script is how
 * a correction reaches Aivy. Run it again after any edit (GitHub → Actions →
 * Sync Document Library). The sheet must be shared (Viewer) with the service
 * account this script prints first.
 *
 * The sheet is one tab, in the order of the printed book: terms, systems,
 * supplies (label tables first give labels per roll, then the Indian Chrome
 * rate per 1000, then one column per material = chrome rate x the multiplier
 * in its heading), then products with no brochure and points to confirm.
 * Sections are separated by an empty row and start with a title cell ("A.",
 * "B.", "C1." ...). The parser checks every material rate against
 * chrome x multiplier and refuses to write if one is off, so a slip made while
 * editing the sheet stops here instead of reaching a client meeting.
 *
 * Local run:  GOOGLE_APPLICATION_CREDENTIALS=key.json node scripts/syncPriceBook.cjs
 */

const fs = require("fs");

const PROJECT_ID = "aivy-5c031";
const DEFAULT_SHEET_ID = "1RAIbQbNSVAHYKegAGAT3b1F0NFi9MjMus4KZadvV1zw";
const COLLECTION = "priceBook";
const DOC = "current";

/** RFC 4180 CSV, as Google Sheets exports it. */
function parseCsv(text) {
  const rows = [];
  let row = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          cell += '"';
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell += c;
      }
    } else if (c === '"') {
      quoted = true;
    } else if (c === ",") {
      row.push(cell);
      cell = "";
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
    } else {
      cell += c;
    }
  }
  if (cell !== "" || row.length) {
    row.push(cell);
    rows.push(row);
  }
  return rows.map((r) => r.map((c) => c.trim()));
}

/** A number as the sheet shows it ("26,000", "504", "214.2"), or null. */
function num(v) {
  if (v === undefined || v === null) return null;
  const s = String(v).replace(/,/g, "").trim();
  if (!/^-?\d+(\.\d+)?$/.test(s)) return null;
  return Number(s);
}

/** Splits the sheet into blocks of non-empty rows. */
function blocks(rows) {
  const out = [];
  let cur = [];
  for (const r of rows) {
    if (r.every((c) => c === "")) {
      if (cur.length) out.push(cur);
      cur = [];
    } else {
      cur.push(r);
    }
  }
  if (cur.length) out.push(cur);
  return out;
}

/** Rows after the header row, as objects keyed by header text. */
function table(rows, headerIndex) {
  const head = rows[headerIndex];
  return rows.slice(headerIndex + 1).map((r) => {
    const o = {};
    head.forEach((h, i) => {
      if (h) o[h] = r[i] ?? "";
    });
    return o;
  });
}

function round2(n) {
  return Math.round(n * 100) / 100;
}

/** A label table: multiplier row, header row, rows. */
function parseLabelBlock(block, key) {
  const multIdx = block.findIndex((r) => r[3] === "Multiplier ->");
  if (multIdx < 0) throw new Error(`${key}: no "Multiplier ->" row`);
  const head = block[multIdx + 1];
  const mult = block[multIdx];
  const baseCol = head.findIndex((h) => /Rs\.\/1000 \(book\)$/.test(h));
  const flagCol = head.indexOf("Check / flag");
  if (baseCol < 0 || flagCol < 0) throw new Error(`${key}: header row not recognised`);
  const rollCols = head.map((h, i) => (/\/roll /.test(h) ? i : -1)).filter((i) => i >= 0);
  const matCols = [];
  for (let i = baseCol + 1; i < flagCol; i++) matCols.push(i);

  const errors = [];
  const rows = block.slice(multIdx + 2).map((r) => {
    const base = num(r[baseCol]);
    if (base === null) errors.push(`${key} ${r[1]}: no base rate`);
    const perRoll = {};
    for (const i of rollCols) perRoll[head[i]] = num(r[i]);
    const rates = {};
    for (const i of matCols) {
      const m = num(mult[i]);
      const v = num(r[i]);
      if (m === null || v === null) {
        errors.push(`${key} ${r[1]}: "${head[i]}" is empty`);
        continue;
      }
      // The cross-check: every material rate must be the base x its multiplier.
      if (base !== null && Math.abs(round2(base * m) - v) > 0.011) {
        errors.push(`${key} ${r[1]}: "${head[i]}" is ${v}, expected ${round2(base * m)} (${base} x ${m})`);
      }
      rates[head[i]] = v;
    }
    return {
      sno: num(r[0]),
      size: r[1],
      ups: num(r[2]),
      note: r[3] || "",
      per_roll: perRoll,
      base_rate: base,
      rates,
      flag: r[flagCol] || "",
    };
  });
  return {
    title: block[0][0],
    base_label: head[baseCol],
    multipliers: Object.fromEntries(matCols.map((i) => [head[i], num(mult[i])])),
    rows,
    errors,
  };
}

/** The whole sheet → the Firestore document. Throws if anything is off. */
function parsePriceBook(csvText) {
  const bl = blocks(parseCsv(csvText));
  const find = (prefix) => bl.find((b) => b[0][0].startsWith(prefix));
  const need = (prefix) => {
    const b = find(prefix);
    if (!b) throw new Error(`Section "${prefix}" is missing from the sheet`);
    return b;
  };

  const terms = table(need("A."), 1).map((t) => ({ section: t.Section, term: t.Term }));

  const systems = table(need("B."), 1).map((s) => {
    const price = num(s["RSP Rs. (GST extra)"]);
    return {
      page: num(s.Page),
      category: s.Category,
      brand: s.Brand,
      model: s.Model,
      description: s.Description,
      price,
      price_text: price === null ? s["RSP Rs. (GST extra)"] || "not listed" : "",
      unit: s.Unit,
      item: s.Item,
      brochure: s.Brochure,
      brochure_link: s["Brochure link"] || "",
      brochure_note: s["Brochure note"] || "",
      brand_note: s["Brand note"] || "",
    };
  });

  const labelKeys = { "C1.": "die_cut", "C2.": "butt_cut", "C3.": "tags", "C4.": "jewellery" };
  const labels = {};
  const errors = [];
  for (const [prefix, key] of Object.entries(labelKeys)) {
    const parsed = parseLabelBlock(need(prefix), key);
    errors.push(...parsed.errors);
    delete parsed.errors;
    labels[key] = parsed;
  }

  const wristbands = table(need("C5."), 1).map((w) => ({
    section: w.Section,
    type: w.Type,
    model: w["Model / size"],
    pack: w.Pack,
    price_pack: num(w["RSP Rs. per pack/box"]),
    price_band: num(w["RSP Rs. per band"]),
  }));
  const tapes = table(need("C6."), 1).map((t) => ({
    section: t.Section,
    size: t.Size,
    price_roll: num(t["RSP Rs. per roll"]),
  }));

  const rb = need("C7.");
  const rHead = rb.findIndex((r) => r[0] === "S.No.");
  const sHead = rb.findIndex((r) => r[0] === "Printer");
  if (rHead < 0 || sHead < 0) throw new Error("C7 ribbons: header rows not found");
  const ribbons = {
    note: [rb[0][0], rb[1][0]].join(" "),
    per_sqm: table(rb.slice(0, sHead - 1), rHead).map((x) => ({
      sno: num(x["S.No."]),
      group: x.Group,
      type: x["Ribbon type"],
      per_sqm: num(x["RSP Rs. per sq m"]),
    })),
    structure: table(rb, sHead).map((x) => ({
      printer: x.Printer,
      core_id: x["Core I.D."],
      core_length: x["Core length"],
      widths: x["Ribbon widths"],
      lengths: x["Ribbon length"],
    })),
  };

  const ph = need("C8.");
  const printheads = {
    note: ph[0][0],
    rows: table(ph, 1).map((x) => ({
      group: x.Group,
      model: x["Printer model"],
      dpi: num(x.DPI),
      price: num(x["RSP Rs."]),
    })),
  };

  const mb = need("C9.");
  const multipliers = {
    note: mb[0][0],
    rows: table(mb, 1).map((x) => ({
      group: x.Group,
      material: x.Material,
      multiplier: num(x.Multiplier),
      multiplier_text: num(x.Multiplier) === null ? x.Multiplier : "",
      applied_to: x["Applied to"],
      note: x.Note || "",
    })),
  };

  const noBrochure = table(need("D."), 1).map((x) => ({
    status: x.Status,
    category: x.Category,
    brand: x.Brand,
    model: x.Model,
    why: x.Why,
  }));
  const doubts = table(need("E."), 1).map((x) => ({ type: x.Type, point: x.Point, status: x.Status || "" }));

  const supplyNotes = need("C. SUPPLIES").map((r) => r[0]).slice(1);

  for (const [what, n, min] of [
    ["terms", terms.length, 20],
    ["systems", systems.length, 50],
    ["die-cut labels", labels.die_cut.rows.length, 100],
    ["ribbons", ribbons.per_sqm.length, 5],
    ["printheads", printheads.rows.length, 10],
  ]) {
    if (n < min) errors.push(`only ${n} ${what} rows read (expected at least ${min}) - has the sheet's layout changed?`);
  }
  for (const s of systems) {
    if (!s.model) errors.push(`a systems row has no model (page ${s.page})`);
  }
  if (errors.length) {
    throw new Error(`The price sheet did not pass its checks:\n- ${errors.join("\n- ")}`);
  }

  return {
    terms,
    systems,
    labels,
    supply_notes: supplyNotes,
    wristbands,
    tapes,
    ribbons,
    printheads,
    multipliers,
    no_brochure: noBrochure,
    doubts,
  };
}

function serviceAccountEmail() {
  const p = process.env.GOOGLE_APPLICATION_CREDENTIALS;
  if (!p) return "(unknown - GOOGLE_APPLICATION_CREDENTIALS is not set)";
  try {
    return JSON.parse(fs.readFileSync(p, "utf8")).client_email || "(no client_email in key)";
  } catch {
    return "(could not read the key file)";
  }
}

async function main() {
  const admin = require("firebase-admin");
  const { GoogleAuth } = require("google-auth-library");
  const sheetId = (process.env.PRICE_SHEET_ID || "").trim() || DEFAULT_SHEET_ID;
  const email = serviceAccountEmail();
  console.log(`Service account: ${email}`);
  console.log(`Price sheet ${sheetId} must be shared with that address (Viewer).`);

  const auth = new GoogleAuth({ scopes: ["https://www.googleapis.com/auth/drive.readonly"] });
  const client = await auth.getClient();
  let meta;
  let csv;
  try {
    meta = (
      await client.request({
        url: `https://www.googleapis.com/drive/v3/files/${sheetId}?fields=id,name,modifiedTime&supportsAllDrives=true`,
      })
    ).data;
    csv = (
      await client.request({
        url: `https://www.googleapis.com/drive/v3/files/${sheetId}/export?mimeType=text%2Fcsv`,
        responseType: "text",
      })
    ).data;
  } catch (e) {
    const status = e && e.response ? e.response.status : null;
    if (status === 403 || status === 404) {
      throw new Error(`No access to the price sheet. Share it with ${email} (Viewer) and run again.`);
    }
    throw e;
  }
  console.log(`Reading "${meta.name}" (modified ${meta.modifiedTime})`);

  const book = parsePriceBook(String(csv));
  admin.initializeApp({ projectId: PROJECT_ID });
  await admin
    .firestore()
    .collection(COLLECTION)
    .doc(DOC)
    .set({
      ...book,
      sheetId,
      sheetName: meta.name,
      sheetModifiedTime: meta.modifiedTime,
      syncedAtMs: Date.now(),
    });
  const labelRows = Object.values(book.labels).reduce((n, t) => n + t.rows.length, 0);
  console.log(
    `Done. ${book.systems.length} system rows, ${labelRows} label/tag rows, ` +
      `${book.ribbons.per_sqm.length} ribbons, ${book.printheads.rows.length} printheads, ` +
      `${book.terms.length} terms. Every material rate matched chrome x multiplier.`,
  );
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e && e.message ? e.message : e);
    process.exit(1);
  });
}

module.exports = { parseCsv, parsePriceBook };

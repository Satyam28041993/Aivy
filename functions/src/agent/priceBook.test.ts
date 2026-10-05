/**
 * The price book: the sheet is parsed and cross-checked, and get_price hands
 * back the rows as the book has them. Every number here is made up — the real
 * price book never enters this repository, which is public.
 */

import { createRequire } from "module";
import { describe, expect, it, vi } from "vitest";

vi.mock("firebase-admin/firestore", () => ({ getFirestore: vi.fn() }));
vi.mock("firebase-functions", () => ({ logger: { warn: vi.fn() } }));

import { lookupPrice, pickRates, ribbonRollPrice, sizeKeys, type PriceBook } from "./priceBook";

const require = createRequire(import.meta.url);
const { parsePriceBook, parseCsv } = require("../../scripts/syncPriceBook.cjs") as {
  parsePriceBook: (csv: string) => PriceBook;
  parseCsv: (csv: string) => string[][];
};

const MULT_HEAD =
  ',,,Multiplier ->,,,,,1.25,2.0,1.5\n' +
  'S.No.,Size (mm W x H),Ups,Note,Labels/roll 50 m,Labels/roll 100 m,Labels/roll 200 m,Indian Chrome Rs./1000 (book),Custom printed Chrome (+25%),PP White (2.00 x Chrome),Thermal Transfer (TT paper) (1.50 x Chrome),Check / flag\n';

function sheet(ppWhite50x50 = "200"): string {
  const terms = Array.from({ length: 20 }, (_, i) => `Payment,${i + 1}. Term number ${i + 1}.`).join("\n");
  const systems = Array.from(
    { length: 50 },
    (_, i) => `9,Filler,Brand,FILL-${i},Filler row,1000,per unit,Product,NOT FOUND,,,`,
  ).join("\n");
  const dies = Array.from({ length: 100 }, (_, i) => `${i + 3},9X${i + 1},1,,10,20,40,10,12.5,20,15`).join("\n");
  return [
    "Title row",
    "",
    "A. COMMERCIAL TERMS & CONDITIONS",
    "Section,Term",
    "Warranty,\"1. Hardware: 1 year for printers, 3 years for scanners.\"",
    terms,
    "",
    "B. SYSTEMS",
    "Page,Category,Brand,Model,Description,RSP Rs. (GST extra),Unit,Item,Brochure,Brochure link,Brochure note,Brand note",
    '4,Barcode printers,Toshiba TEC,BX410T,"4"" printer, 300 dpi",1000,per unit,Product,Toshiba BX410T,https://drive/bx410t,,',
    "4,Barcode printers,Toshiba TEC,BX410T/BX420T: cutter module,Cutter,200,per unit,Accessory,Toshiba BX410T,https://drive/bx410t,BX400-series accessory,",
    "4,Barcode printers,Toshiba TEC,BX420T,4 inch flat head,900,per unit,Product,Toshiba BX410T,https://drive/bx410t,PARTIAL: check,",
    "10,Barcode readers,Cognex,DM-8700 (2D/DPM),DPM reader,On request,on request,Product,NOT FOUND,,No brochure,Brand not printed",
    systems,
    "",
    "C. SUPPLIES",
    "How to read the label tables.",
    "",
    "C1. DIE-CUT LABELS",
    MULT_HEAD +
      `1,50X50,1,,955,1910,3820,100,125,${ppWhite50x50},150\n` +
      "2,50X75,1,,630,1260,2520,140,175,280,210,Price faint in photo - check book\n" +
      "3,25mm Round,1,,1805,3610,7220,30,37.5,60,45\n" +
      dies,
    "",
    "C2. BUTT-CUT LABELS",
    MULT_HEAD + "1,50X50,1,,985,1970,3940,90,112.5,180,135",
    "",
    "C3. PLAIN TAGS",
    ",,,Multiplier ->,,,,,3.0",
    "S.No.,Size (mm W x H),Ups,Note,Tags/roll 25 m,Tags/roll 50 m,Tags/roll 100 m,Tag Rs./1000 (book),Synthetic Tag (3.00 x Tag price),Check / flag",
    '1,"1"" X 2""",,,493,985,1970,50,150',
    "",
    "C4. JEWELLERY LABELS",
    MULT_HEAD + "1,70X10,1,gap 2.7mm,3935,7870,15740,20,25,40,30",
    "",
    "C5. WRIST BANDS",
    "Section,Type,Model / size,Pack,RSP Rs. per pack/box,RSP Rs. per band",
    'Wrist bands,Compu band,"Adult 1"" wide",200 pcs/box,1000,5',
    "",
    "C6. TAPES",
    "Section,Size,RSP Rs. per roll",
    'Fabric tape,"1"" x 200 m",100',
    "",
    "C7. RIBBONS",
    "Roll price = width x length / 1000 x rate.",
    "S.No.,Group,Ribbon type,RSP Rs. per sq m,110 mm x 100 m roll",
    "1,Printing ribbon,Wax (Premium),10,110",
    "2,Printing ribbon,Resin (Flat head),30,330",
    "3,Printing ribbon,Eco-Wax,5,55",
    "4,Printing ribbon,Wax-Resin (Flat head),20,220",
    "5,Printing ribbon,Resin (Near edge),30,330",
    "Ribbon structure by printer",
    "Printer,Core I.D.,Core length,Ribbon widths,Ribbon length",
    "BX400,25.4 mm,Flush,110 mm,100 - 600 m",
    "",
    "C8. PRINT HEADS",
    "Group,Printer model,DPI,RSP Rs.",
    ...Array.from({ length: 9 }, (_, i) => `Toshiba TEC,FILL${i},300,1000`),
    "Toshiba TEC,B-EX4T1,300,5000",
    "",
    "C9. LABEL MATERIAL MULTIPLIERS",
    "Group,Material,Multiplier,Applied to,Note",
    "Filmic,PP White,2.0,Indian Chrome,",
    "",
    "D. PRODUCTS WITH NO BROCHURE",
    "Status,Category,Brand,Model,Why",
    "Missing,Readers,Cognex,DM-8700,no brochure",
    "",
    "E. POINTS TO CONFIRM",
    "Type,Point",
    "Faint price,50X75 was faint.",
  ].join("\n");
}

const book = parsePriceBook(sheet());

describe("syncPriceBook parser", () => {
  it("reads quoted cells with commas and doubled quotes", () => {
    expect(parseCsv('a,"b, c","4"" wide"\n')).toEqual([["a", "b, c", '4" wide']]);
  });

  it("reads every section of the sheet", () => {
    expect(book.terms[0].section).toBe("Warranty");
    expect(book.systems.find((s) => s.model === "BX410T")?.price).toBe(1000);
    expect(book.systems.find((s) => s.model.startsWith("DM-8700"))).toMatchObject({ price: null, price_text: "On request" });
    expect(book.labels.die_cut.rows[0]).toMatchObject({
      size: "50X50",
      per_roll: { "Labels/roll 50 m": 955, "Labels/roll 100 m": 1910, "Labels/roll 200 m": 3820 },
      base_rate: 100,
    });
    expect(book.labels.tags.base_label).toBe("Tag Rs./1000 (book)");
    expect(book.ribbons.per_sqm).toHaveLength(5);
    expect(book.ribbons.structure[0].printer).toBe("BX400");
    expect(book.printheads.rows.at(-1)).toMatchObject({ model: "B-EX4T1", price: 5000 });
  });

  it("refuses a sheet where a material rate is not chrome x multiplier", () => {
    // PP White should be 100 x 2.0 = 200.
    expect(() => parsePriceBook(sheet("210"))).toThrow(/PP White .* is 210, expected 200/);
  });

  it("refuses a sheet that has lost a section", () => {
    expect(() => parsePriceBook(sheet().replace("C8. PRINT HEADS", "C8 renamed"))).toThrow(/C8\./);
  });
});

describe("get_price lookup", () => {
  it("finds a label by size, in every table that has it, per roll first", () => {
    const r = lookupPrice(book, "50x50 label ka rate") as Record<string, any>;
    expect(r.labels).toHaveLength(2); // die-cut and butt-cut
    expect(r.labels[0].labels_per_roll["Labels/roll 50 m"]).toBe(955);
    expect(r.labels[0]["Indian Chrome Rs./1000 (book)"]).toBe(100);
    expect(r.basics[0]).toMatch(/GST extra/);
    expect(r.label_basics).toMatch(/x the multiplier/);
  });

  it("narrows to the material asked for", () => {
    const r = lookupPrice(book, "50 x 50", "PP white") as Record<string, any>;
    expect(r.labels[0].rates_per_1000).toEqual({ "PP White (2.00 x Chrome)": 200 });
    const tt = lookupPrice(book, "50x50", "thermal transfer") as Record<string, any>;
    expect(Object.keys(tt.labels[0].rates_per_1000)).toEqual(["Thermal Transfer (TT paper) (1.50 x Chrome)"]);
  });

  it("does not let every heading's 'x Chrome' match 'chrome'", () => {
    const rates = { "Chrome (ECO) (0.85 x Chrome)": 1, "DT Paper (ECO) (1.25 x Chrome)": 2 };
    expect(pickRates(rates, "chrome eco")).toEqual({ "Chrome (ECO) (0.85 x Chrome)": 1 });
  });

  it("repeats a row's check note", () => {
    const r = lookupPrice(book, "50x75") as Record<string, any>;
    expect(r.labels[0].check).toMatch(/faint/);
  });

  it("offers the other orientation instead of guessing", () => {
    const r = lookupPrice(book, "75x50") as Record<string, any>;
    expect(r.labels).toBeUndefined();
    expect(r.labels_other_orientation[0].size_w_x_h).toBe("50X75");
    expect(r.orientation_note).toMatch(/other way round/);
  });

  it("reads round labels and inch tags", () => {
    expect(sizeKeys("25mm round")).toContain("25MMROUND");
    const round = lookupPrice(book, "25mm round label") as Record<string, any>;
    expect(round.labels[0].size_w_x_h).toBe("25mm Round");
    const tag = lookupPrice(book, '1" x 2" tag') as Record<string, any>;
    expect(tag.labels[0].table).toMatch(/TAGS/);
  });

  it("finds a printer by model with its accessories, not its neighbours", () => {
    const r = lookupPrice(book, "BX410T price") as Record<string, any>;
    expect(r.systems.map((s: any) => s.model)).toEqual(["BX410T", "BX410T/BX420T: cutter module"]);
    expect(r.systems[0].brochure_link).toBe("https://drive/bx410t");
  });

  it("says 'on request' rather than inventing a number", () => {
    const r = lookupPrice(book, "DM-8700") as Record<string, any>;
    expect(r.systems[0].price).toBe("On request");
  });

  it("works out a ribbon roll from the per-square-metre rate", () => {
    expect(ribbonRollPrice(10, 110, 100)).toBe(110);
    const r = lookupPrice(book, "wax ribbon 110mm 300m") as Record<string, any>;
    const wax = r.ribbons.find((x: any) => x.type === "Wax (Premium)");
    expect(wax["roll_110mm_x_300m"]).toBe(330);
    expect(r.ribbon_basics).toMatch(/printer make and model/);
  });

  it("finds a printhead by printer model", () => {
    const r = lookupPrice(book, "B-EX4T1 printhead") as Record<string, any>;
    expect(r.printheads).toEqual([{ group: "Toshiba TEC", model: "B-EX4T1", dpi: 300, price: 5000 }]);
  });

  it("answers terms questions from the book, without dragging in products", () => {
    const r = lookupPrice(book, "warranty kitna hai") as Record<string, any>;
    expect(r.terms[0].term).toMatch(/1 year/);
    const moq = lookupPrice(book, "MOQ for Barcode printers") as Record<string, any>;
    expect(moq.systems).toBeUndefined();
  });

  it("does not offer the other orientation when the asked one exists", () => {
    const r = lookupPrice(book, "50x50") as Record<string, any>;
    expect(r.labels_other_orientation).toBeUndefined();
  });

  it("returns nothing for what the book does not have", () => {
    expect(lookupPrice(book, "laptop")).toBeNull();
  });
});

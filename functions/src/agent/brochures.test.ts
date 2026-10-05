/**
 * Finding the right file when the user asks in a hurry, usually with a model
 * number typed the way it is said, in front of a client.
 */

import { describe, expect, it } from "vitest";

import {
  BROCHURE_CATALOG,
  buildProductSelector,
  rankBrochures,
  type BrochureDoc,
} from "./brochures";

function doc(driveId: string, fileName: string, category: string): BrochureDoc {
  return {
    driveId,
    fileName,
    title: fileName.replace(/\.[a-z]+$/i, ""),
    category,
    url: `https://example.test/${driveId}`,
    sizeBytes: 1_048_576,
  };
}

const DOCS: BrochureDoc[] = [
  doc("1hNOFp1QoNqm_avON-Kg1BOLcaowC8O8m", "DS-2208 2D DS2278-BT.pdf", "Scanner"),
  doc("13cu83bMH0V9jm1GIE9jFZtkPTJ_I-fBE", "LS-2208.pdf", "Scanner"),
  doc("1MgLfOoO7Je-9XDgnZVTAm2Ojsn247-Ee", "EX4T1.pdf", "Printer"),
  doc("1Ik3_-MIDhud5_lmUNMWpgPxQwB5qu0Ie", "T4000 RFID PRINTER.pdf", "Printer"),
  doc("1RXbRCon2N7_bMHVnxaNcsYVdOzGpsvzz", "DLD NCNR  updated.docx", "Dino Labels Digital Labels"),
  doc("1b7kT2bSyEA_9dtGEpCtHSJ5X0QTFdTqO", "Sales Cheat Sheet.docx", "Dino Labels Digital Labels"),
  doc("unknown-new-file", "Honeywell PM45.pdf", "Printer"),
];

describe("rankBrochures", () => {
  it("finds a model typed without its hyphen", () => {
    const [top] = rankBrochures(DOCS, "ds2208 ka brochure bhejo");
    expect(top.model).toContain("DS2208");
  });

  it("does not confuse DS2208 with LS2208", () => {
    const [top] = rankBrochures(DOCS, "LS2208");
    expect(top.model).toBe("LS2208");
  });

  it("finds a Toshiba model by the name a client says", () => {
    const [top] = rankBrochures(DOCS, "B-EX4T1");
    expect(top.model).toBe("B-EX4T1");
  });

  it("finds a form by what it is called", () => {
    const [top] = rankBrochures(DOCS, "NCNR form");
    expect(top.title).toContain("NCNR");
  });

  it("finds a product by what it does", () => {
    const names = rankBrochures(DOCS, "rfid printer").map((m) => m.model);
    expect(names).toContain("T4000");
  });

  it("still finds a file added later that has no catalog entry", () => {
    const [top] = rankBrochures(DOCS, "PM45");
    expect(top.title).toBe("Honeywell PM45");
    expect(top.summary).toBeNull();
  });

  it("marks internal sales documents", () => {
    const [top] = rankBrochures(DOCS, "cheat sheet");
    expect(top.share_with_client).toBe(false);
    const [form] = rankBrochures(DOCS, "NCNR");
    expect(form.share_with_client).toBe(true);
  });

  it("lists everything when asked for nothing in particular", () => {
    expect(rankBrochures(DOCS, "")).toHaveLength(DOCS.length);
  });

  it("returns nothing rather than a random file", () => {
    expect(rankBrochures(DOCS, "coffee machine")).toHaveLength(0);
  });
});

describe("catalog", () => {
  it("covers every brochure and document that was read", () => {
    // 34 brochures + 21 training documents.
    expect(Object.keys(BROCHURE_CATALOG)).toHaveLength(55);
  });

  it("puts products, not forms, in the prompt's product list", () => {
    const sel = buildProductSelector();
    expect(sel).toContain("B-EX4T1");
    expect(sel).toContain("DS3608");
    expect(sel).not.toContain("NCNR");
  });
});

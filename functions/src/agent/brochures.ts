/**
 * Great Eastern's product brochures: what each one is, where its download link
 * lives, and how Aivy finds the right one when asked.
 *
 * The files sit in two of the user's Drive folders: "NEW BROUCHER" (Printer,
 * Scanner, Mobile Computer, Bartender) and "01 Training & Company Knowledge"
 * (profiles, webinars, the DinoLabelDigital forms, templates and decks — Word,
 * PowerPoint and Excel included, because any of them may be wanted in front of
 * a client). `scripts/syncBrochures.cjs` copies them
 * into Firebase Storage and writes one Firestore row per file in `brochures/`,
 * keyed by the Drive file id, carrying a download link anyone can open — so it
 * can go straight to a client on WhatsApp.
 *
 * The catalog below is the part a file name cannot carry: the model number as
 * a client says it, the maker, what the product is for. It was written from
 * reading every brochure. It is keyed by Drive id so a renamed file still
 * matches; a brochure added later with no entry here still turns up by its
 * file name and folder, just without a summary.
 *
 * `buildProductSelector()` renders the same catalog into the prompt, so the
 * product list the model recommends from and the brochures it can hand over
 * are one list and cannot drift apart.
 */

import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";

import { dataResult, fail, type ToolContext, type ToolResult } from "./toolTypes";

export const BROCHURE_COLLECTION = "brochures";

export type BrochureKind =
  | "printer"
  | "mobile printer"
  | "print & apply"
  | "scanner"
  | "mobile computer"
  | "software"
  | "document";

export interface CatalogEntry {
  /** As the client would say it: "DS2208", "B-EX4T1". */
  model: string;
  brand: string;
  kind: BrochureKind;
  /** One line: what it is and who it suits. Facts from the brochure only. */
  summary: string;
  /** Extra words a request might use that the summary does not contain. */
  keywords: string[];
  /**
   * Written for the sales team, not for a client — the cheat sheet, the
   * process guide with the team's phone numbers. Aivy still hands it over,
   * but says so, because a forwarded link cannot be taken back.
   */
  internal?: boolean;
}

/** Keyed by Drive file id. */
export const BROCHURE_CATALOG: Record<string, CatalogEntry> = {
  // ---- Printers ----------------------------------------------------------
  "1iwdLopdtLYkGyqG5q2eDg1E5qXrjg7VO": {
    model: "BV400 (BV410D/BV420D, BV410T/BV420T, BV420D-GL)",
    brand: "Toshiba",
    kind: "printer",
    summary:
      "4-inch desktop printer, direct thermal (D) or thermal transfer (T), 203/300 dpi, up to 7 ips; optional UHF RFID on T models; BV420D-GL prints linerless labels. Retail shops, offices, small counters.",
    keywords: ["desktop", "compact", "linerless", "rfid", "retail", "office", "4 inch"],
  },
  "1JszMorF4P74nXEgSEXT91mBXztCYK_RB": {
    model: "SLP-TX400 / SLP-TX403",
    brand: "Bixolon",
    kind: "printer",
    summary:
      "4-inch desktop thermal transfer/direct thermal printer, 203 dpi (TX400, 7 ips) or 300 dpi (TX403, 5 ips); optional UHF RFID encoding of closely spaced inlays, Ethernet, cutter. Budget desktop RFID.",
    keywords: ["desktop", "rfid", "4 inch", "tx400", "budget"],
  },
  "15f4YkgVMg6YThs5pp_UkuLpf881lFACn": {
    model: "B-FV4 (B-FV4D / B-FV4T)",
    brand: "Toshiba",
    kind: "printer",
    summary:
      "Compact 4-inch desktop printer, direct thermal (B-FV4D) or thermal transfer (B-FV4T), up to 6 ips, 300 m ribbon. Office/asset labels, healthcare wristbands and specimen labels, courier and shelf labels.",
    keywords: ["desktop", "compact", "wristband", "hospital", "courier", "office", "fv4"],
  },
  "10Owpt8GVYhmmZwx7-qY6DIyTkzPKT0N-": {
    model: "BA400 (BA410T metal / BA420T plastic)",
    brand: "Toshiba",
    kind: "printer",
    summary:
      "Mid-range 4-inch thermal transfer printer, 203/300 dpi, up to 8 ips, Bluetooth with NFC pairing built in, optional dual-band Wi-Fi and UHF RFID. BA410 for factory floors, BA420 where space is tight.",
    keywords: ["mid range", "midrange", "rfid", "bluetooth", "manufacturing", "ba410", "ba420"],
  },
  "1Ik3_-MIDhud5_lmUNMWpgPxQwB5qu0Ie": {
    model: "T4000",
    brand: "TSC Printronix",
    kind: "printer",
    summary:
      "Compact light-industrial 4-inch metal printer, 203/300 dpi, up to 10 ips, about 5,000 labels a day; optional UHF RFID encoder that also does on-metal tags and reprints any label that fails to encode.",
    keywords: ["light industrial", "rfid", "on metal", "printronix", "tsc", "4 inch"],
  },
  "1MgLfOoO7Je-9XDgnZVTAm2Ojsn247-Ee": {
    model: "B-EX4T1",
    brand: "Toshiba",
    kind: "printer",
    summary:
      "Industrial 4-inch near-edge printer, 203/305 dpi, up to 14 ips, 600 m ribbon, ribbon save and RFID kit options. High-volume factory, logistics and pharma labelling.",
    keywords: ["industrial", "high volume", "near edge", "rfid", "ex4t1", "4 inch"],
  },
  "1NiI7qDhHIs6LbDd3zH_h9yl3q9me-Wu4": {
    model: "B-EX4T2",
    brand: "Toshiba",
    kind: "printer",
    summary:
      "Low-cost industrial 4-inch flat-head printer, 203/300 dpi at up to 12 ips or 600 dpi at 6 ips, 800 m ribbon, ZPL emulation to replace existing (Zebra) printer fleets without software changes.",
    keywords: ["industrial", "zebra replacement", "zpl", "flat head", "600 dpi", "ex4t2"],
  },
  "19C4t7CK32cct6NWjpK36AFzq2BUi5ZdN": {
    model: "B-EX4T3",
    brand: "Toshiba",
    kind: "printer",
    summary:
      "High-precision 600 dpi industrial printer, ±0.3 mm print position, labels as short as 3 mm. PCB and electronics labels, rating plates, cosmetics ingredient and pharma product labels with tiny text.",
    keywords: ["600 dpi", "small label", "pcb", "electronics", "high precision", "ex4t3"],
  },
  "10u8G-tKUOqv48Nbc25UHKFBDwD4IUwWW": {
    model: "BX410T",
    brand: "Toshiba",
    kind: "printer",
    summary:
      "Next-gen industrial 4-inch printer, 203/305 dpi, up to 14 ips, A-BRID OS (prints PDFs directly, runs stand-alone apps with a scanner and no PC, cloud fleet management), 800 m ribbon, optional UHF/HF RFID.",
    keywords: ["industrial", "pdf", "standalone", "cloud", "rfid", "bx410"],
  },
  "196BuZftVoro7dcWu2IAu1zT4ZKq3sOT5": {
    model: "B-EX6T",
    brand: "Toshiba",
    kind: "printer",
    summary:
      "Industrial 6-inch printer (160 mm print width), 203/305 dpi, up to 12 ips, 800 m ribbon, RFID on the near-edge model. Carton, pallet and other large labels.",
    keywords: ["6 inch", "wide", "carton", "pallet", "industrial", "ex6"],
  },
  "1q1TICyR0vOKkBFuLXZgsZM4UoPFxKwnA": {
    model: "B-SX6 / B-SX8",
    brand: "Toshiba",
    kind: "printer",
    summary:
      "Heavy-duty steel wide-web printers, 305 dpi, up to 8 ips: B-SX6 prints 170 mm wide, B-SX8 213 mm (about 8 inches). Large compliance labels in steel, paper, chemical and automotive plants; RFID kits.",
    keywords: ["wide web", "8 inch", "6 inch", "steel", "heavy duty", "sx8", "sx6"],
  },
  "1EpZ2nNm87PYaMxPONjBUkbse--6e-SBe": {
    model: "B-852",
    brand: "Toshiba",
    kind: "printer",
    summary:
      "Wide-web 8.5-inch (216.8 mm) 300 dpi printer, 4 ips, steel body; prints A4 documents and large labels and can replace a laser printer (optional PCL5).",
    keywords: ["a4", "wide", "8 inch", "laser replacement", "852"],
  },
  "13yuJZTTKAN3LBnfhUyJHFlH1J4ksM0Wh": {
    model: "T6000e / T8000 with ODV-2D",
    brand: "TSC Printronix",
    kind: "printer",
    summary:
      "Prints and verifies every barcode in one pass: grades 1D/2D codes to ISO 15415/15416, up to 50 per label, overstrikes and reprints a bad label by itself and keeps a report; the T6000e also encodes RFID in the same pass. For compliance labelling where a bad barcode means a fine or a rejected shipment.",
    keywords: ["verification", "verifier", "odv", "compliance", "grading", "pharma", "t6000"],
  },
  "1AJN-eO75mf_4XIrRIoqNUTStb1IU9zqf": {
    model: "B-FP2D / B-FP3D",
    brand: "Toshiba",
    kind: "mobile printer",
    summary:
      "Portable direct thermal label/receipt printers: B-FP2D 2-inch (54 mm), B-FP3D 3-inch (72 mm), up to 6 ips, Bluetooth/Wi-Fi, IP54. Shelf markdowns, delivery receipts, field service tickets.",
    keywords: ["mobile", "portable", "handheld printer", "receipt", "bluetooth", "2 inch", "3 inch"],
  },
  "1txzgdqCwkn52z-kUl4829xgOzJUpWUej": {
    model: "SPP-L310",
    brand: "Bixolon",
    kind: "mobile printer",
    summary:
      "3-inch mobile direct thermal label printer, 72 mm print width, up to 5 ips, Bluetooth/Wi-Fi with NFC pairing, IP54, 1.8 m drop, 385 g. Warehouse, healthcare, retail and ticketing on the move.",
    keywords: ["mobile", "portable", "3 inch", "bluetooth", "linerless"],
  },
  "1sEMNoxtHTFCtX76T_pG5UjNAzitoIYvZ": {
    model: "XPA 93x",
    brand: "Novexx",
    kind: "print & apply",
    summary:
      "Compact print & apply system, 4/5/6-inch print widths, 300 dpi, labels up to 185 mm wide, mounts in any position on a line, tool-free maintenance, ribbon save, remote web control. Products, cartons and pallets.",
    keywords: ["print and apply", "automatic", "production line", "inline", "carton", "pallet"],
  },
  "1vZJbMuGxoYKIqVycm-pfKuWG9zZ7h-vK": {
    model: "ALX 92x / ALX 73x",
    brand: "Novexx",
    kind: "print & apply",
    summary:
      "Industrial print & apply for 24/7 lines: ALX 92x prints and applies 1:1 at up to 400 mm/s; ALX 73x is the high-speed model, up to 400 labels a minute. Blow-on, touch-on and swing-on applicators.",
    keywords: ["print and apply", "high speed", "24/7", "applicator", "production line", "alx"],
  },

  // ---- Scanners ----------------------------------------------------------
  "13cu83bMH0V9jm1GIE9jFZtkPTJ_I-fBE": {
    model: "LS2208",
    brand: "Zebra",
    kind: "scanner",
    summary:
      "Corded 1D laser handheld scanner, the long-time best seller; reads ordinary 1D barcodes up to about 63 cm, 5-year warranty. Cannot read QR or other 2D codes.",
    keywords: ["1d", "laser", "basic", "budget", "billing", "pos", "corded"],
  },
  "1hNOFp1QoNqm_avON-Kg1BOLcaowC8O8m": {
    model: "DS2208 (corded) / DS2278 (cordless)",
    brand: "Zebra",
    kind: "scanner",
    summary:
      "Affordable 1D/2D handheld imager: reads QR and barcodes on paper or phone screens; DS2278 is Bluetooth with a full-shift battery. Billing counters, coupons, light warehouse use.",
    keywords: ["2d", "qr", "affordable", "pos", "billing", "cordless", "bluetooth", "wireless"],
  },
  "1cfcMS8HR5EqGx5-bEiT6SG35yq1wS_Z5": {
    model: "DS8108 (corded) / DS8178 (cordless)",
    brand: "Zebra",
    kind: "scanner",
    summary:
      "Premium 1D/2D handheld imager: reads damaged and dense codes, up to about 61 cm range, parses GS1 labels (expiry, lot), cordless DS8178 has 100 m Bluetooth range. Busy checkouts, receiving, pharma.",
    keywords: ["2d", "premium", "gs1", "cordless", "bluetooth", "long range", "pharma"],
  },
  "1FyjaQ3I1FNWBeikWLjSqLH6Xp2Tw81rP": {
    model: "DS3608 (corded) / DS3678 (cordless)",
    brand: "Zebra",
    kind: "scanner",
    summary:
      "Ultra-rugged 1D/2D handheld scanner for warehouses, manufacturing and harsh, dusty or cold sites; corded or cordless.",
    keywords: ["rugged", "industrial", "warehouse", "cold storage", "freezer", "2d", "cordless"],
  },
  "1gpQUwBPW-uo7wVlkvZq4OxvqIXFisLwH": {
    model: "DS9308",
    brand: "Zebra",
    kind: "scanner",
    summary:
      "Compact hands-free presentation 1D/2D scanner with a tiny footprint; reads phone screens and through cellophane, IP52. Retail, pharmacy and restaurant counters, ticketing.",
    keywords: ["presentation", "hands free", "counter", "2d", "qr", "retail", "pharmacy"],
  },
  "1ppzA2PpYe0LefodUku3xri2zLhCmKq9L": {
    model: "DS7708",
    brand: "Zebra",
    kind: "scanner",
    summary:
      "On-counter 1D/2D slot scanner, swipe speeds up to 100 in/s, widest field of view, EAS tag deactivation. Busy supermarket checkout lanes.",
    keywords: ["on counter", "supermarket", "checkout", "presentation", "hands free"],
  },
  "1W8-wA9P_Xs_XbCfVZbkkQlCDxCQqAx5p": {
    model: "MP7000",
    brand: "Zebra",
    kind: "scanner",
    summary:
      "Multi-plane bioptic scanner with built-in scale (15 kg) for the busiest checkout and self-checkout lanes; optional colour camera for produce recognition and loss prevention.",
    keywords: ["bioptic", "scale", "weighing", "supermarket", "hypermarket", "checkout"],
  },
  "13aP_LAVfFv0BJLoKWdANto-1E0KBIQRG": {
    model: "QB30",
    brand: "Denso",
    kind: "scanner",
    summary:
      "Fixed-mount 2D scanner that fits small spaces and reads moving objects (up to 800 mm/s), up to 8 codes at once, IP54, -20 to 50 °C, USB or RS-232. Kiosks, entry gates, production lines.",
    keywords: ["fixed", "fixed mount", "kiosk", "gate", "production line", "conveyor", "qr"],
  },
  "1tEbIRjPNgoHp_EVPUCpZfgaiH4nG7DOn": {
    model: "SF1",
    brand: "Denso",
    kind: "scanner",
    summary:
      "Pocket-size Bluetooth 2D scanner (80 g) that pairs with an Android/iOS phone or tablet, wearable option, wipe-down body, IP54, 24-hour battery. Bedside scanning in hospitals and other mobile work.",
    keywords: ["healthcare", "hospital", "wearable", "bluetooth", "pocket", "phone", "ios"],
  },

  // ---- Mobile computers --------------------------------------------------
  "19ZhUo73aJ8FSHAy4xcJhgo2sZC64_kpU": {
    model: "EA630 Plus",
    brand: "Unitech",
    kind: "mobile computer",
    summary:
      "6-inch Android 11 rugged smartphone with 2D scanner, NFC, 4G and Wi-Fi, IP65, 1.2 m drop; optional UHF RFID gun grip. Retail stock, hospitality, healthcare.",
    keywords: ["android", "smartphone", "touch", "rfid", "pda", "handheld", "retail"],
  },
  "1wq7OHsv0vY44relxalJvlRFVuzu0zRrC": {
    model: "BHT-M60",
    brand: "Denso",
    kind: "mobile computer",
    summary:
      "Android 10 rugged keypad handheld: reads about 30 labels a second by tracing along a shelf, scans from 1 m, reads film-wrapped and DPM codes, OCR; IP65/IP67, 3 m drop, 4G option. Logistics and manufacturing.",
    keywords: ["android", "keypad", "rugged", "pda", "handheld", "warehouse", "dpm", "ocr"],
  },
  "1iHXQmS2SPDL_HYtD9QVZyBXrEnnrQngu": {
    model: "HT682A",
    brand: "Unitech",
    kind: "mobile computer",
    summary:
      "Android 10 rugged 4-inch keypad terminal with long-range 2D scanning (up to 20 m), 6,700 mAh hot-swap battery, IP65/IP67, 2.4 m drop with bumper, 4G option. High-rack warehouses and inventory.",
    keywords: ["android", "keypad", "long range", "warehouse", "rack", "pda", "rugged"],
  },
  "12vN7R_6RIELUkgAbVsS4kjbE7VFmUSDd": {
    model: "BHT-1500",
    brand: "Denso",
    kind: "mobile computer",
    summary:
      "Lightweight (128 g) non-Android 1D batch terminal running on AA-size eneloop or alkaline AAA cells (up to 85 hours); Bluetooth model sends to phones/tablets. Simple, low-cost stock counting.",
    keywords: ["batch", "basic", "budget", "1d", "stock count", "lightweight"],
  },
  "1g44795c4SW-OD7LE326kLg84VqWk2j1Z": {
    model: "BHT-1700 / BHT-1800",
    brand: "Denso",
    kind: "mobile computer",
    summary:
      "Denso Android handheld terminals. This brochure is pictures only — open the PDF for the specifications.",
    keywords: ["android", "handheld", "pda"],
  },

  // ---- Software ----------------------------------------------------------
  "1at9SBjSuXFJVlZCm2JJRYMG4qLprvdfX": {
    model: "BarTender (quick reference: editions)",
    brand: "Seagull Scientific",
    kind: "software",
    summary:
      "Label design and printing software. Professional for small sites (databases, RFID encoding); Automation for printing automatically from ERP/WMS; Enterprise for multi-site and regulated industries.",
    keywords: ["bartender", "label software", "label design", "editions"],
  },
  "1EbXs9wLyo8bFSnx-OOwdiMX1c4tjSUbL": {
    model: "BarTender Starter vs Professional",
    brand: "Seagull Scientific",
    kind: "software",
    summary:
      "Edition comparison: Starter covers up to 3 printers with Excel/CSV data; Professional adds SQL/SAP/Oracle databases, advanced serialisation, conditional printing, data-entry forms, RFID encoding and PDF output.",
    keywords: ["bartender", "starter", "professional", "comparison"],
  },
  "11q5CsPJAiXFjoI0PwDZWLXKCmRGDcM4o": {
    model: "BarTender Professional / Automation / Enterprise",
    brand: "Seagull Scientific",
    kind: "software",
    summary:
      "Feature chart: Automation adds Integration Builder (print automatically from SAP, Oracle, web services, file drop) and Process Builder; Enterprise adds Librarian, web/mobile Print Portal, audit trail, e-signatures and printer failover.",
    keywords: ["bartender", "automation", "enterprise", "sap", "integration"],
  },

  // ---- Company and training documents ------------------------------------
  // From "Great Eastern IDTech Work" → "01 Training & Company Knowledge".
  "1wCBS9hTl9mFGkH-bA8AH3Bs62gYL-HGk": {
    model: "GEIPL Business Profile",
    brand: "Great Eastern IDTech",
    kind: "document",
    summary: "Company presentation: est. 1983, AIDC solutions, hardware, supplies, software, services, offices, partners and reference customers.",
    keywords: ["company profile", "business profile", "about us", "introduction", "geipl"],
  },
  "15X0EqggYPkndEhIMZmV_-UgfzAqP3M3Z": {
    model: "GEIPL Business Profile 2025",
    brand: "Great Eastern IDTech",
    kind: "document",
    summary: "The 2025 edition of the company presentation.",
    keywords: ["company profile", "business profile", "2025", "about us", "geipl"],
  },
  "1s5f4gWf9k90veDzLrthZXxtXaPSo-NSD": {
    model: "GEIPL WMS Features",
    brand: "Great Eastern IDTech",
    kind: "document",
    summary: "Warehouse Management System deck: challenges without a WMS, functions (GRN, putaway, picking, kitting, QC, cross-docking, stock audit), ERP integration and reports.",
    keywords: ["wms", "warehouse management", "software", "inventory"],
  },
  "15J82gfAy5sVqRpJFeX5rpCgz178QqCga": {
    model: "UHF RFID Product Portfolio",
    brand: "Great Eastern IDTech",
    kind: "document",
    summary: "RFID readers (fixed, desktop, handheld, sleds), RFID printers, hard tags, tags and inlays with specifications.",
    keywords: ["rfid", "uhf", "reader", "tag", "inlay", "antenna", "portfolio"],
  },
  "1S8SfMalhu2HhgRk30JudMg1udKlSIuQM": {
    model: "Webinar: self-adhesive label materials & usage",
    brand: "Great Eastern IDTech",
    kind: "document",
    summary: "Training webinar on PS labels: adhesives, papers, films, security and direct thermal stocks by application, market growth, how to choose a label.",
    keywords: ["webinar", "label material", "adhesive", "training", "ps label"],
  },
  "1Z_fHk8PxAmBgsr-OzNcDh2K9ni2P_9nJ": {
    model: "Webinar: thermal transfer ribbons",
    brand: "Great Eastern IDTech",
    kind: "document",
    summary: "Training webinar on TTR: construction, wax / wax-resin / resin / near-edge / colour ribbons and where each is used.",
    keywords: ["webinar", "ttr", "ribbon", "wax", "resin", "training"],
  },
  "1_3gCLti_E8Ig7_PQ3CFvqRKLZJz3ZVvh": {
    model: "GEIPL logo",
    brand: "Great Eastern IDTech",
    kind: "document",
    summary: "Company logo image.",
    keywords: ["logo", "image"],
  },
  "1jQ-u6mmdp1eH5_Rp5X3EZaZwuk6ou-U2": {
    model: "DinoLabelDigital Company Profile",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "Digital brand-label business profile: press, capability, why digital, markets, sustainable materials, value-add services.",
    keywords: ["dino", "digital label", "company profile", "brand label"],
  },
  "1ySHj353E72l2e6vqhgvPVuFL4CdGSJTQ": {
    model: "DinoLabelDigital Pitch Deck",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "PowerPoint pitch deck for digitally printed brand labels.",
    keywords: ["dino", "pitch deck", "presentation", "ppt", "digital label"],
  },
  "1B3OqLnHbe46woVod88td-6VbNnGxhAF8": {
    model: "Digital Printing Value Proposition",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "Offset vs flexo vs digital comparison: MOQ, lead time, sampling, pre-press, variable data, cost.",
    keywords: ["dino", "digital vs flexo", "comparison", "value proposition"],
  },
  "1o4S244d0MsOmYjDXPLg8wU7XH3C8jRA2": {
    model: "Label Material Portfolio",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "Materials for digital labels — semi-gloss paper, PP, silver PP, clear, kraft, flexi-film, sustainable — with the label selection questionnaire.",
    keywords: ["dino", "material", "pp", "kraft", "clear", "paper"],
  },
  "1MTryvVzRGKAFBVd2X7RiTY1yq-2jE17A": {
    model: "Label Selection Checklist",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "Form for the client to fill: product, surface, shape, material, finish, exposure, value-adds and application method.",
    keywords: ["dino", "checklist", "questionnaire", "form", "requirement"],
  },
  "1-e_siXW5AkLVKGrifAwf5IbOHN_ourHy": {
    model: "Artwork Guidelines 2.0",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "How to prepare label artwork: file formats, bleed, safe zone, fonts, CMYK, barcode size and placement rules.",
    keywords: ["dino", "artwork", "design", "guidelines", "barcode", "bleed"],
  },
  "1ddTtkKuPxG-iZXvg12Tvpqn8-ul8hxOL": {
    model: "Prototyping Proposition Deck",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "Label prototyping service: intake questions, pain points solved, service tiers A/B/C, who benefits.",
    keywords: ["dino", "prototype", "prototyping", "sample", "npd"],
  },
  "19oxgboOwGjmXPU3YU9Jp5P3ty9s5C2gY": {
    model: "Quotation Format",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "Word template for a digital-label quotation with the standard terms (MOV, GST, freight, advance, lead time, ±10%).",
    keywords: ["dino", "quotation", "quote", "template", "word", "terms"],
  },
  "1RXbRCon2N7_bMHVnxaNcsYVdOzGpsvzz": {
    model: "NCNR Order Agreement (updated)",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "Non-cancellable, non-reschedulable, non-returnable form the client signs before a first order.",
    keywords: ["dino", "ncnr", "form", "agreement", "first order", "word"],
  },
  "1ud6cTRKYIaxXYQ8u5LPnfj94gfzoYVP2": {
    model: "NCNR Order Agreement (older copy)",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "An earlier copy of the NCNR form — send the updated one.",
    keywords: ["dino", "ncnr", "form", "old"],
  },
  "1hLQMPo53NiYRjSUFGU4BxXWijvaLA2Df": {
    model: "Brand Authorisation Letter",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "Letter the client signs confirming the right to use the brand name and artwork, needed before a first order.",
    keywords: ["dino", "authorisation", "authorization", "brand", "letter", "form", "word"],
  },
  "1b7kT2bSyEA_9dtGEpCtHSJ5X0QTFdTqO": {
    model: "Sales Cheat Sheet",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "Ideal customers, MOV logic, turnaround, digital vs flexo and how to defend the price.",
    keywords: ["dino", "cheat sheet", "sales", "mov", "pricing"],
    internal: true,
  },
  "1PQ6cY8kCeF6RwOj4-lBEyhA3INHDgGPN": {
    model: "Sales & Order Process Guide",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "What to collect for a quote, documents for a first order, the backend process, and the Dino team's contacts.",
    keywords: ["dino", "process", "order", "sop", "team", "contacts"],
    internal: true,
  },
  "1zthKTSp9pPLLwVcFog8pLtLFBEnhFm6I": {
    model: "Industry Known Challenges",
    brand: "DinoLabelDigital",
    kind: "document",
    summary: "Excel sheet: each industry's labelling pain points and how digital printing answers them.",
    keywords: ["dino", "industry", "challenges", "pain points", "excel"],
    internal: true,
  },
};

/** One row in Firestore `brochures/{driveId}`, written by the sync script. */
export interface BrochureDoc {
  driveId: string;
  title: string;
  fileName: string;
  /** The Drive sub-folder it sits in: Printer, Scanner, Mobile Computer… */
  category: string;
  url: string;
  sizeBytes?: number;
}

export interface BrochureMatch {
  title: string;
  model: string | null;
  brand: string | null;
  kind: string;
  summary: string | null;
  link: string;
  size_mb: number | null;
  /** False for sales-team material; say so before it goes to a client. */
  share_with_client: boolean;
}

/** Lower-case words, plus each word with hyphens and spaces squeezed out. */
function words(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .split(" ")
    .filter((w) => w.length > 0);
}

function compact(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, "");
}

const STOP = new Set([
  "the", "a", "an", "of", "for", "and", "or", "ka", "ki", "ke", "ko", "do", "de",
  "brochure", "brochures", "broucher", "pdf", "catalog", "catalogue", "link",
  "send", "share", "bhejo", "dedo", "chahiye", "please", "me", "mujhe",
  "document", "documents", "doc", "file", "files", "wala", "waala",
]);

/**
 * How well a brochure answers a query. A model number typed without its
 * hyphen ("ds2208", "bex4t1") must still hit, so every query word is also
 * looked for in the squeezed form of the haystack.
 */
export function scoreBrochure(doc: BrochureDoc, query: string): number {
  const entry = BROCHURE_CATALOG[doc.driveId];
  const hay = [
    doc.title,
    doc.fileName,
    doc.category,
    entry?.model ?? "",
    entry?.brand ?? "",
    entry?.kind ?? "",
    entry?.summary ?? "",
    ...(entry?.keywords ?? []),
  ].join(" ");
  const hayWords = new Set(words(hay));
  const hayCompact = compact(hay);
  const modelCompact = compact(`${entry?.model ?? ""} ${doc.fileName}`);

  let score = 0;
  for (const w of words(query)) {
    if (STOP.has(w)) continue;
    if (modelCompact.includes(w) && /\d/.test(w)) {
      // A model number is the strongest signal there is.
      score += 5;
    } else if (hayWords.has(w)) {
      score += 2;
    } else if (w.length >= 3 && hayCompact.includes(w)) {
      score += 1;
    }
  }
  // "B-EX4T1" typed as "b ex4t1" splits into two words; try the whole query
  // squeezed as well.
  const q = compact(query);
  if (q.length >= 4 && /\d/.test(q) && modelCompact.includes(q)) {
    score += 5;
  }
  return score;
}

export function toMatch(doc: BrochureDoc): BrochureMatch {
  const entry = BROCHURE_CATALOG[doc.driveId];
  return {
    title: doc.title,
    model: entry?.model ?? null,
    brand: entry?.brand ?? null,
    kind: entry?.kind ?? doc.category,
    summary: entry?.summary ?? null,
    link: doc.url,
    size_mb:
      typeof doc.sizeBytes === "number"
        ? Math.round((doc.sizeBytes / (1024 * 1024)) * 10) / 10
        : null,
    share_with_client: !entry?.internal,
  };
}

/** Pure ranking, so it can be tested without Firestore. */
export function rankBrochures(
  docs: BrochureDoc[],
  query: string,
  limit = 5,
): BrochureMatch[] {
  if (!query.trim()) {
    return docs
      .slice()
      .sort((a, b) => a.category.localeCompare(b.category) || a.title.localeCompare(b.title))
      .map(toMatch);
  }
  return docs
    .map((d) => ({ d, s: scoreBrochure(d, query) }))
    .filter((x) => x.s > 0)
    .sort((a, b) => b.s - a.s)
    .slice(0, limit)
    .map((x) => toMatch(x.d));
}

async function loadBrochures(): Promise<BrochureDoc[]> {
  const snap = await getFirestore().collection(BROCHURE_COLLECTION).get();
  const out: BrochureDoc[] = [];
  for (const doc of snap.docs) {
    const d = doc.data();
    if (typeof d.url !== "string" || !d.url) continue;
    out.push({
      driveId: doc.id,
      title: String(d.title ?? d.fileName ?? doc.id),
      fileName: String(d.fileName ?? ""),
      category: String(d.category ?? ""),
      url: d.url,
      ...(typeof d.sizeBytes === "number" ? { sizeBytes: d.sizeBytes } : {}),
    });
  }
  return out;
}

export async function findDocumentTool(
  _ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const query = typeof args.query === "string" ? args.query.trim() : "";
  let docs: BrochureDoc[];
  try {
    docs = await loadBrochures();
  } catch (e) {
    logger.warn("find_document: read failed", {
      err: e instanceof Error ? e.message : String(e),
    });
    return fail("failed", "I couldn't open the document library just now.");
  }
  if (docs.length === 0) {
    return fail(
      "nothing_found",
      "The document library is empty — the files have not been copied from Drive to Firebase yet.",
    );
  }
  const matches = rankBrochures(docs, query);
  if (matches.length === 0) {
    return fail(
      "nothing_found",
      `Nothing in the library matches "${query}". It holds ${docs.length} files; try a model number, a product type (printer, scanner, mobile computer, BarTender) or a document name (profile, NCNR, quotation format).`,
    );
  }
  return dataResult({ query, count: matches.length, files: matches });
}

/** The catalog as prompt text: one line per product, grouped by kind. */
export function buildProductSelector(): string {
  const order: Array<Exclude<BrochureKind, "document">> = [
    "printer",
    "mobile printer",
    "print & apply",
    "scanner",
    "mobile computer",
    "software",
  ];
  const heading: Record<Exclude<BrochureKind, "document">, string> = {
    printer: "Label printers",
    "mobile printer": "Mobile printers",
    "print & apply": "Print & apply",
    scanner: "Barcode scanners",
    "mobile computer": "Mobile computers (handheld terminals)",
    software: "Software",
  };
  const entries = Object.values(BROCHURE_CATALOG).filter((e) => e.kind !== "document");
  return order
    .map((kind) => {
      const lines = entries
        .filter((e) => e.kind === kind)
        .map((e) => `- **${e.brand} ${e.model}** — ${e.summary}`);
      return `**${heading[kind]}**\n${lines.join("\n")}`;
    })
    .join("\n\n");
}

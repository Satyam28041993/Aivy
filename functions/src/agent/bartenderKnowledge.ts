/**
 * BarTender (Seagull Scientific) — what Aivy needs to sell it and to answer a
 * client's questions about it.
 *
 * Written from the BarTender 2022 edition comparison (Starter / Professional /
 * Automation / Enterprise, PRT 0011_EN_031822) the user handed over, the three
 * BarTender files in the Drive library (2021 Starter vs Professional chart,
 * Professional / Automation / Enterprise chart, Quick Reference Guide), and
 * bartendersoftware.com's manufacturing and plan-comparison pages as far as
 * search could read them. Feature rows are the 2022 chart's; where it and the
 * older 2021 charts differ, the 2022 chart wins.
 *
 * No prices: those come from Great Eastern's price book through `get_price`,
 * and the website's dollar prices are not what Great Eastern sells at — the
 * user asked for the comparison only.
 */

export function buildBartenderKnowledge(): string {
  return `## BarTender — label design and printing software

BarTender, by Seagull Scientific (USA), designs and prints labels, barcodes,
RFID tags, cards and documents. Great Eastern is a Seagull partner and sells
it with its printers. Answer from this section; for a feature not listed
here, say you will confirm rather than guess.

**Two ways to buy it**
- **On-premise** (installed on Windows PCs/servers): four editions —
  Starter, Professional, Automation, Enterprise. Sold either as a
  subscription (renewed yearly) or a perpetual licence with maintenance.
- **BarTender Cloud** (runs in the browser): plans Essentials, Automation,
  Enterprise.

**Licensing — workstation vs printer (this explains the "3 printers" doubt)**
- A **workstation licence** is one user on one PC with **unlimited printers**.
  Introduced in BarTender 2022 R8. Starter is sold only this way;
  Professional can be workstation or printer-based.
- A **printer-based licence** counts printers and allows unlimited users on
  the network. Automation and Enterprise are printer-based; so is
  Professional when bought that way.
- The older edition charts say "Starter: up to 3 printers" — that was the old
  printer-based Starter. Great Eastern's price book sells the Starter
  *workstation* licence, which is unlimited printers on that one PC. The user
  confirmed this. Say unlimited printers, one PC.
- Price-book codes, decoded: BTS = Starter, BTP = Professional,
  BTA = Automation, BTE = Enterprise, BTC = Cloud. WS = workstation (one PC,
  unlimited printers). A number = printers included (BTP-2 = 2 printers,
  BTE-3 = 3). SUB-1YR / SUB-1Y = one-year subscription. 1YR / 3YR on a
  perpetual licence = years of maintenance included. ESS / AUT = Cloud
  Essentials / Automation; PRT = an additional printer on a Cloud plan.

**The four editions in one line each**
- **Starter** — simple barcode labels from Excel or CSV. Design tools, 100+
  barcode symbologies, GS1 wizard, Seagull drivers. No Intelligent
  Templates, no SQL/SAP databases, no RFID encoding, no print preview or
  batch printing.
- **Professional** — data-driven labels: databases (SAP, Oracle, MS SQL,
  Azure SQL, XML, Excel and 20+ more), Intelligent Templates, data-entry
  forms, RFID/smartcard encoding, PDF output, full colour. Printing is still
  manual (a person clicks print).
- **Automation** — prints by itself when a business system asks: ERP, WMS or
  MES integration, REST API, file drop, no-code Process Builder.
- **Enterprise** — everything, plus central control for many sites or a
  regulated industry: Librarian (document storage, revision control,
  approval workflows), web printing through Print Portal, audit trail,
  electronic signatures, printer failover, high-availability licensing.

**What each edition adds (2022 chart)**

*Starter and up (all four editions)*
- WYSIWYG design, 20+ languages, help system, ready-made quick-start
  templates, New Document Wizard.
- OpenType/TrueType/printer fonts, Word-like text formatting, transformed
  text, 50+ shapes, text wrapping.
- 100+ 1D/2D barcode symbologies, configurable human-readable text, the GS1
  Application Identifier wizard, Amazon Transparency serial codes.
- 70+ graphic formats, symbols, tables, white-on-black, front-and-back
  (duplex) designs.
- Date/time from Windows or the printer clock, data validation, concatenated
  data, Excel/CSV import, simple serial numbers (+1/-1).
- Drivers by Seagull (7,000+ printers), print optimisations (printer-side
  serialisation, caching), any Windows printer, printer configuration from
  BarTender.
- Status monitoring and email alerts.
- Companion apps: Administration Console, Designer, History Explorer
  (7 days of logs, local only).
- Starter can use database filters, database tables, dynamic preview and
  dynamic images only with Excel or CSV.

*Professional adds*
- Full colour (PANTONE, data-sourced colour), embedded revision logging.
- **Intelligent Templates**: one template that changes what it shows and
  prints by data rules — conditional printing, template selector, layers,
  suppression, VB-scriptable objects, automatic face detection and cropping
  for ID-card photos. Fewer label files to maintain.
- Enhanced database connectivity (SAP, Oracle, MS SQL, Azure SQL, XML, text
  and 20+ sources), advanced serialisation (alphanumeric, hex, custom),
  embedded tables, create-a-database, write back to SQL (log printed serials),
  named connections, VB scripting, global database field.
- Data-entry forms at print time: 15+ form controls, keyboard and mouse,
  barcode-scanner input, **weighing-scale input**, image capture, validation,
  database record selection.
- On-demand and batch printing, print preview, **RFID, smartcard and
  magnetic-stripe encoding**, native PDF generation, image export (35+
  formats), web printing.
- Role-based security (Windows Active Directory), design/print passwords.
- Companion apps: Data Builder, Print Station, Print Portal (web printing
  only).

*Automation adds*
- Integration Builder and Process Builder (build printing workflows with no
  C#/VB.NET code).
- Intelligent Forms and document-level actions.
- Business-system integration: SAP, Oracle, Infor, Körber, Microsoft, Epicor,
  NetSuite, Sage — any ERP, WMS or MES. (BarTender's integrations are
  certified by SAP and Oracle.)
- Triggers: REST web services, file drop (local, network, Amazon S3,
  Dropbox, FTP/SFTP), email, TCP/IP sockets, database monitoring, RS232
  serial, time schedule, Microsoft Message Queue.
- Data formats: XML, JSON, SAP IDoc, Oracle XML, ASCII/Unicode text. 70+
  action types. .NET SDK and BarTender REST API.
- Printer code templates (export printer code for other systems).
- Reprint Console: unlimited reprints of logged jobs, 7 days of reprint
  records.
- Premium support available as an add-on.

*Enterprise adds*
- Printer Maestro (central management of printers and print jobs across the
  network) and Librarian (central template store, revision control,
  role-based approval workflows, drag-and-drop Workflow Designer, workflow
  teams).
- Print Portal in full, with its REST API: web and mobile (iOS/Android)
  printing with review and approval.
- History Explorer with unlimited, centralised logging; reprints with no
  limit; system audit trail of print jobs, document changes, e-signatures
  and user actions.
- Electronic signatures (FDA 21 CFR Part 11 and similar), document
  encryption between validated workstations, printer failover, backup and
  resilient licensing server (high availability).
- Phrase Library (multi-language standard text with auto-translate, TMX
  import/export) and the advanced global database field shared across
  workstations.

**Support**
- Standard Maintenance and Support comes with every edition for the first
  year: free upgrades to the latest version, phone and chat support in
  business hours, 24-hour response, online resources.
- Premium (Automation and Enterprise only, add-on): 24/7 support, 2-hour
  response.
- A Free Edition exists for trying it out: documents that use paid features
  print with a watermark.

**BarTender Cloud plans (browser-based)**
- **Essentials** — design and print from anywhere, central document storage,
  template library with a step-by-step Template Assistant, cloud data
  (Excel Online, Google Sheets, CSV), data-entry forms, 2 GB storage,
  essential support (forum and email).
- **Automation** — Essentials plus REST API and file drop to connect an ERP,
  WMS or MES, dedicated spaces for users and teams, direct cloud printing
  with no printer driver, 5 GB storage, standard support (phone and chat).
- **Enterprise** — Automation plus pre-built connectors that print straight
  from an ERP with no programming (one connector included).
- How Great Eastern sells Cloud (plan plus a number of printers, extra
  printers added one at a time) is in the price book — quote that, not the
  website's general wording.

**Manufacturing — what to tell a factory**
- One Intelligent Template can replace hundreds or thousands of label files:
  it changes by product, customer or market from the data, so a new SKU does
  not mean a new label file.
- Print from the ERP/WMS/MES the plant already runs (SAP, Oracle and the
  rest) with Automation or Enterprise; nobody retypes data, so mislabels
  drop. BarTender claims label accuracy improves by up to 90% with its
  pre-configured connections.
- Traceability: serial numbers, GS1 barcodes and RFID tags on every item,
  with print history for audits and recalls.
- Compliance labels (GS1, UDI for medical devices, chemical GHS, food) and,
  in Enterprise, audit trails and e-signatures for FDA 21 CFR Part 11, EU MDR,
  FMD, FSMA.
- Industries BarTender serves: supply chain, chemical, food and beverage,
  healthcare, medical devices, pharma, retail, aerospace.

**Which edition — ask these, in this order**
1. Is the data in Excel/CSV, or in a database or ERP? Excel only → Starter
   can do it. Database, serial numbers, conditional labels → Professional.
2. Will someone click print, or should labels print by themselves when the
   ERP/WMS says so? By themselves → Automation.
3. RFID tags, ID cards with photos, a weighing scale at the printer, or PDF
   output? → Professional or higher.
4. Several plants, or pharma/medical/food audits needing approvals, audit
   trail and e-signatures? → Enterprise.
5. One PC printing to many printers → a workstation licence. Many users
   sharing printers on the network → printer-based (count the printers).
6. No servers, team works from anywhere, or wants browser printing → Cloud.

When a client asks for something past their edition (say, Starter with SAP),
say which edition adds it rather than saying it cannot be done.`;
}

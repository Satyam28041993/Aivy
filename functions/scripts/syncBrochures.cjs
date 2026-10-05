/**
 * Copies the Great Eastern brochures and training documents from the user's
 * Google Drive into Firebase Storage, and writes one Firestore row per file in
 * `brochures/{driveFileId}` with a download link anyone can open. Aivy's
 * `find_document` tool reads those rows (functions/src/agent/brochures.ts).
 *
 * Runs in GitHub Actions ("Sync Document Library"), with the same service
 * account the deploy uses. That account can only read folders that have been
 * shared with it, so the Drive folders below must be shared (Viewer) with the
 * service-account email this script prints first.
 *
 * Safe to run again: a file whose Drive modifiedTime has not changed is
 * skipped, and an existing download token is kept so links already sent to
 * clients keep working. Files removed from Drive are removed here too. Two
 * copies of the same file (same checksum) are stored once.
 *
 * It also pulls the readable text out of every PDF, Word, PowerPoint and Excel
 * file into `brochureText/{driveFileId}`, so Aivy can read a whole brochure
 * when asked for a specification instead of knowing only its one-line summary.
 * Text is kept in its own collection because it is large and only one
 * document's worth is wanted at a time; the library listing stays small.
 *
 * Local run:  GOOGLE_APPLICATION_CREDENTIALS=key.json node scripts/syncBrochures.cjs
 */

const crypto = require("crypto");
const fs = require("fs");
const admin = require("firebase-admin");
const { GoogleAuth } = require("google-auth-library");

const PROJECT_ID = "aivy-5c031";
const BUCKET = "aivy-5c031.firebasestorage.app";
const COLLECTION = "brochures";
const TEXT_COLLECTION = "brochureText";
/** Firestore caps a document at 1 MiB; the longest brochure is far below this. */
const MAX_TEXT_CHARS = 300000;
const STORAGE_PREFIX = "library";

/** Drive folders to mirror. Sub-folders are walked; each file's folder becomes its category. */
const DEFAULT_FOLDERS = [
  "12hsDUOgE0xYvKtWT5A9aXhl4BvPV7p3T", // brochures (NEW BROUCHER/…)
  "1M22B-bx6lydA-KIinFKNl-FqOOCocsBG", // Great Eastern IDTech Work / 01 Training & Company Knowledge
];

const FOLDER_MIME = "application/vnd.google-apps.folder";

/** Google-native files have no bytes of their own; export them to an Office format. */
const EXPORTS = {
  "application/vnd.google-apps.document": {
    mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ext: ".docx",
  },
  "application/vnd.google-apps.spreadsheet": {
    mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ext: ".xlsx",
  },
  "application/vnd.google-apps.presentation": {
    mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ext: ".pptx",
  },
};

/** Plain text of a file, or "" for a type that has none (images). */
async function extractText(buf, mimeType, fileName) {
  const name = fileName.toLowerCase();
  if (mimeType === "application/pdf" || name.endsWith(".pdf")) {
    const { PDFParse } = require("pdf-parse");
    const parser = new PDFParse({ data: buf });
    try {
      return (await parser.getText()).text || "";
    } finally {
      await parser.destroy();
    }
  }
  if (name.endsWith(".docx")) {
    const mammoth = require("mammoth");
    return (await mammoth.extractRawText({ buffer: buf })).value || "";
  }
  if (name.endsWith(".pptx") || name.endsWith(".xlsx")) {
    const JSZip = require("jszip");
    const zip = await JSZip.loadAsync(buf);
    const parts = Object.keys(zip.files)
      .filter((f) =>
        name.endsWith(".pptx")
          ? /^ppt\/slides\/slide\d+\.xml$/.test(f)
          : f === "xl/sharedStrings.xml",
      )
      .sort((a, b) => (parseInt(a.replace(/\D/g, ""), 10) || 0) - (parseInt(b.replace(/\D/g, ""), 10) || 0));
    const out = [];
    for (const f of parts) {
      const xml = await zip.file(f).async("string");
      const runs = [...xml.matchAll(/<(?:a:t|t)(?:\s[^>]*)?>([^<]*)<\/(?:a:t|t)>/g)].map((m) => m[1]);
      out.push(runs.join(" "));
    }
    return out
      .join("\n\n")
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'");
  }
  return "";
}

/**
 * Some brochures are pictures of text, or embed fonts that come out as
 * symbol soup. Saying "unreadable" is better than handing the model noise to
 * quote from.
 */
function looksReadable(text) {
  const t = text.replace(/\s+/g, " ").trim();
  if (t.length < 200) return false;
  const plain = (t.match(/[A-Za-z0-9 .,:;()%/+-]/g) || []).length;
  const words = (t.match(/\b[A-Za-z]{3,}\b/g) || []).length;
  return plain / t.length > 0.85 && words > 40;
}

function folderIds() {
  const raw = (process.env.LIBRARY_FOLDER_IDS || "").trim();
  return raw ? raw.split(",").map((s) => s.trim()).filter(Boolean) : DEFAULT_FOLDERS;
}

function serviceAccountEmail() {
  const p = process.env.GOOGLE_APPLICATION_CREDENTIALS;
  if (!p) return "(unknown — GOOGLE_APPLICATION_CREDENTIALS is not set)";
  try {
    return JSON.parse(fs.readFileSync(p, "utf8")).client_email || "(no client_email in key)";
  } catch {
    return "(could not read the key file)";
  }
}

async function main() {
  const email = serviceAccountEmail();
  console.log(`Service account: ${email}`);
  console.log("Each Drive folder below must be shared with that address (Viewer).");

  const auth = new GoogleAuth({
    scopes: [
      "https://www.googleapis.com/auth/drive.readonly",
      "https://www.googleapis.com/auth/cloud-platform",
    ],
  });
  const client = await auth.getClient();

  async function drive(path, params, responseType) {
    const url = new URL(`https://www.googleapis.com/drive/v3/${path}`);
    for (const [k, v] of Object.entries(params || {})) url.searchParams.set(k, String(v));
    const res = await client.request({ url: url.toString(), responseType: responseType || "json" });
    return res.data;
  }

  function explain(e, what) {
    const status = e && e.response ? e.response.status : null;
    const body = e && e.response && e.response.data ? JSON.stringify(e.response.data) : String(e);
    if (/accessNotConfigured|SERVICE_DISABLED|has not been used/.test(body)) {
      return `${what}: the Google Drive API is not enabled in project ${PROJECT_ID}. Enable it at https://console.cloud.google.com/apis/library/drive.googleapis.com?project=${PROJECT_ID} and run again.`;
    }
    if (status === 404 || status === 403) {
      return `${what}: no access. Share the folder with ${email} (Viewer) and run again.`;
    }
    return `${what}: ${body}`;
  }

  /** Walks a folder; returns [{file, category}] for every non-folder inside it. */
  async function walk(folderId, category, out, depth) {
    let pageToken;
    do {
      const data = await drive("files", {
        q: `'${folderId}' in parents and trashed = false`,
        fields: "nextPageToken, files(id, name, mimeType, modifiedTime, size, md5Checksum)",
        pageSize: 200,
        supportsAllDrives: true,
        includeItemsFromAllDrives: true,
        ...(pageToken ? { pageToken } : {}),
      });
      for (const f of data.files || []) {
        if (f.mimeType === FOLDER_MIME) {
          if (depth < 6) await walk(f.id, f.name, out, depth + 1);
        } else {
          out.push({ file: f, category });
        }
      }
      pageToken = data.nextPageToken;
    } while (pageToken);
  }

  const found = [];
  for (const id of folderIds()) {
    let root;
    try {
      root = await drive(`files/${id}`, { fields: "id, name", supportsAllDrives: true });
    } catch (e) {
      throw new Error(explain(e, `Folder ${id}`));
    }
    console.log(`Reading "${root.name}" (${id})`);
    await walk(id, root.name, found, 0);
  }
  console.log(`Found ${found.length} files in Drive.`);

  admin.initializeApp({ projectId: PROJECT_ID, storageBucket: BUCKET });
  const db = admin.firestore();
  const bucket = admin.storage().bucket();
  const existing = new Map();
  for (const doc of (await db.collection(COLLECTION).get()).docs) existing.set(doc.id, doc.data());

  const seenIds = new Set();
  const seenChecksums = new Set();
  const textDocs = new Map();
  for (const doc of (await db.collection(TEXT_COLLECTION).get()).docs) {
    textDocs.set(doc.id, doc.get("extractedFrom"));
  }

  let copied = 0;
  let unchanged = 0;
  let skipped = 0;
  let texts = 0;

  async function saveText(file, buf, fileName, contentType) {
    let text = "";
    try {
      text = await extractText(buf, contentType, fileName);
    } catch (e) {
      console.log(`  text: could not read ${fileName}: ${e && e.message ? e.message : e}`);
    }
    text = text.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
    const readable = looksReadable(text);
    await db.collection(TEXT_COLLECTION).doc(file.id).set({
      driveId: file.id,
      fileName,
      readable,
      text: readable ? text.slice(0, MAX_TEXT_CHARS) : "",
      chars: text.length,
      extractedFrom: file.modifiedTime,
      extractedAtMs: Date.now(),
    });
    texts++;
    console.log(`  text: ${fileName} — ${readable ? `${text.length} chars` : "not readable (images or odd fonts)"}`);
  }

  async function download(file, exp) {
    const bytes = exp
      ? await drive(`files/${file.id}/export`, { mimeType: exp.mime }, "arraybuffer")
      : await drive(`files/${file.id}`, { alt: "media", supportsAllDrives: true }, "arraybuffer");
    return Buffer.from(bytes);
  }

  for (const { file, category } of found) {
    const exp = EXPORTS[file.mimeType];
    if (file.mimeType.startsWith("application/vnd.google-apps.") && !exp) {
      console.log(`  skip (no download form): ${file.name}`);
      skipped++;
      continue;
    }
    if (file.md5Checksum) {
      if (seenChecksums.has(file.md5Checksum)) {
        console.log(`  skip (duplicate of a file already stored): ${category}/${file.name}`);
        skipped++;
        continue;
      }
      seenChecksums.add(file.md5Checksum);
    }
    seenIds.add(file.id);

    const prev = existing.get(file.id);
    const fileName = exp && !file.name.endsWith(exp.ext) ? `${file.name}${exp.ext}` : file.name;
    const contentType = exp ? exp.mime : file.mimeType;
    const textCurrent = textDocs.get(file.id) === file.modifiedTime;

    if (prev && prev.url && prev.driveModifiedTime === file.modifiedTime && prev.category === category) {
      unchanged++;
      if (!textCurrent) {
        await saveText(file, await download(file, exp), fileName, contentType);
      }
      continue;
    }

    const buf = await download(file, exp);

    const storagePath = `${STORAGE_PREFIX}/${category}/${fileName}`;
    // Keep the old token so a link already forwarded to a client stays valid.
    const token = (prev && prev.downloadToken) || crypto.randomUUID();
    if (prev && prev.storagePath && prev.storagePath !== storagePath) {
      await bucket.file(prev.storagePath).delete({ ignoreNotFound: true });
    }
    await bucket.file(storagePath).save(buf, {
      resumable: false,
      contentType,
      metadata: {
        contentDisposition: `attachment; filename*=UTF-8''${encodeURIComponent(fileName)}`,
        metadata: { firebaseStorageDownloadTokens: token },
      },
    });
    const url =
      `https://firebasestorage.googleapis.com/v0/b/${BUCKET}/o/` +
      `${encodeURIComponent(storagePath)}?alt=media&token=${token}`;

    await db.collection(COLLECTION).doc(file.id).set({
      driveId: file.id,
      title: fileName.replace(/\.[A-Za-z0-9]+$/, ""),
      fileName,
      category,
      mimeType: contentType,
      storagePath,
      downloadToken: token,
      url,
      sizeBytes: buf.length,
      driveModifiedTime: file.modifiedTime,
      ...(file.md5Checksum ? { md5: file.md5Checksum } : {}),
      syncedAtMs: Date.now(),
    });
    copied++;
    console.log(`  copied: ${storagePath} (${(buf.length / 1048576).toFixed(1)} MB)`);
    await saveText(file, buf, fileName, contentType);
  }

  let removed = 0;
  for (const [id, data] of existing) {
    if (seenIds.has(id)) continue;
    if (data.storagePath) await bucket.file(data.storagePath).delete({ ignoreNotFound: true });
    await db.collection(COLLECTION).doc(id).delete();
    await db.collection(TEXT_COLLECTION).doc(id).delete();
    removed++;
    console.log(`  removed (no longer in Drive): ${data.fileName || id}`);
  }

  console.log(
    `Done. ${copied} copied, ${unchanged} unchanged, ${skipped} skipped, ${removed} removed, ` +
      `${texts} texts extracted. ` +
      `${seenIds.size} files in the library.`,
  );
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e && e.message ? e.message : e);
    process.exit(1);
  });
}

module.exports = { extractText, looksReadable };

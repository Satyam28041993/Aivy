/**
 * Grants or removes the Firebase Auth custom claim `admin: true`, which
 * Firestore rules and the WhatsApp settings screen use for writes.
 *
 * Credentials (pick one):
 *
 * 1) Service account JSON (recommended on Windows)
 *    Firebase console → Project settings → Service accounts → Generate new
 *    private key. Save the file locally (do not commit it).
 *
 *    node scripts/setAdminClaim.cjs <UID> --service-account C:\path\to\key.json
 *
 * 2) Application Default Credentials
 *    gcloud auth application-default login
 *
 *    node scripts/setAdminClaim.cjs <UID>
 *
 * Revoke admin:
 *    node scripts/setAdminClaim.cjs <UID> --revoke [--service-account ...]
 *
 * After granting: sign out in the app and sign in again so the ID token refreshes.
 */

const fs = require("fs");
const path = require("path");
const admin = require("firebase-admin");

const PROJECT_ID = "aivy-5c031";

function parseArgs() {
  const raw = process.argv.slice(2);
  const revoke = raw.includes("--revoke");
  let serviceAccountPath = null;
  const saIdx = raw.indexOf("--service-account");
  if (saIdx !== -1 && raw[saIdx + 1] && !raw[saIdx + 1].startsWith("--")) {
    serviceAccountPath = raw[saIdx + 1];
  }
  const skip = new Set();
  if (saIdx !== -1) {
    skip.add(saIdx);
    skip.add(saIdx + 1);
  }
  const positional = raw.filter(
    (a, i) =>
      !skip.has(i) && a !== "--revoke" && a !== "--service-account" && !a.startsWith("--"),
  );
  const uid = positional[0]?.trim();
  return { revoke, serviceAccountPath, uid };
}

const { revoke, serviceAccountPath, uid } = parseArgs();

if (!uid) {
  console.error(
    "Usage: node scripts/setAdminClaim.cjs <FIREBASE_AUTH_UID> [--service-account path/to/key.json] [--revoke]",
  );
  console.error("");
  console.error(
    "Example: node scripts/setAdminClaim.cjs YOUR_UID --service-account C:\\keys\\aivy-service-account.json",
  );
  process.exit(1);
}

function initAdmin() {
  if (admin.apps.length) {
    return;
  }

  const keyPath =
    serviceAccountPath ||
    process.env.GOOGLE_APPLICATION_CREDENTIALS ||
    null;

  if (keyPath) {
    const abs = path.isAbsolute(keyPath)
      ? keyPath
      : path.resolve(process.cwd(), keyPath);
    if (!fs.existsSync(abs)) {
      console.error(`Service account file not found: ${abs}`);
      process.exit(1);
    }
    const json = JSON.parse(fs.readFileSync(abs, "utf8"));
    admin.initializeApp({
      credential: admin.credential.cert(json),
      projectId: PROJECT_ID,
    });
    return;
  }

  admin.initializeApp({ projectId: PROJECT_ID });
}

initAdmin();

async function main() {
  const user = await admin.auth().getUser(uid);
  const claims = { ...(user.customClaims || {}) };
  if (revoke) {
    delete claims.admin;
  } else {
    claims.admin = true;
  }
  await admin.auth().setCustomUserClaims(uid, claims);
  const after = await admin.auth().getUser(uid);
  console.log("OK. Custom claims now:", after.customClaims);
  console.log(
    revoke
      ? "Revoked admin flag. Sign out/in in the app."
      : "Admin granted. Sign out and sign back in in the app (or wait for token refresh).",
  );
}

main().catch((e) => {
  if (e?.code === "app/invalid-credential") {
    console.error(e.message);
    console.error("");
    console.error(
      "No usable credentials. Download a service account JSON from Firebase Console",
    );
    console.error(
      "(Project settings → Service accounts → Generate new private key), then run:",
    );
    console.error("");
    console.error(
      `  node scripts/setAdminClaim.cjs ${uid} --service-account C:\\path\\to\\that-file.json`,
    );
    process.exit(1);
  }
  console.error(e);
  process.exit(1);
});

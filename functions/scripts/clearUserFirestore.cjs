/**
 * Wipes ALL Firestore data under users/{uid} (chats+messages, entries, orders,
 * jobs, reminders, payments, meta, etc.). Does NOT delete the Firebase Auth user.
 *
 * Prerequisites:
 *   gcloud auth application-default login
 *   OR set GOOGLE_APPLICATION_CREDENTIALS to a service account JSON
 *
 * Usage (from the functions/ directory):
 *   node scripts/clearUserFirestore.cjs <UID> --confirm
 *
 * Example:
 *   node scripts/clearUserFirestore.cjs AbCdEf123456 --confirm
 */

const admin = require("firebase-admin");
const { getFirestore } = require("firebase-admin/firestore");

const PROJECT_ID = "aivy-5c031";
const args = process.argv.slice(2);
const confirm = args.includes("--confirm");
const uid = args.find((a) => a !== "--confirm")?.trim();

if (!uid) {
  console.error(
    "Usage: node scripts/clearUserFirestore.cjs <FIREBASE_AUTH_UID> --confirm",
  );
  process.exit(1);
}

if (!confirm) {
  console.error("Refusing: add --confirm to delete all data under users/{uid}.");
  process.exit(1);
}

if (!admin.apps.length) {
  admin.initializeApp({ projectId: PROJECT_ID });
}

const db = getFirestore();
const userDoc = db.doc(`users/${uid}`);

/**
 * If `users/uid` exists, one recursive delete clears the doc and every
 * subcollection. If the doc is missing (rare) but subcollections still exist
 * (e.g. only `chats/.../messages/...` were written), delete each top-level
 * subdoc with recursive delete so nested `messages` are removed too.
 */
async function main() {
  const snap = await userDoc.get();
  console.log(
    `This does NOT remove the Firebase Auth account — only Firestore under users/${uid}.`,
  );
  if (snap.exists) {
    console.log(
      `recursiveDelete: ${userDoc.path} (project ${PROJECT_ID}) + all subcollections...`,
    );
    await db.recursiveDelete(userDoc);
    console.log("Done.");
    return;
  }
  const topLevel = await userDoc.listCollections();
  if (topLevel.length === 0) {
    console.log(`No data under ${userDoc.path} (no doc, no subcollections).`);
    return;
  }
  console.log(
    `Parent document missing; deleting ${topLevel.length} subcollection(s) under ${userDoc.path}...`,
  );
  for (const col of topLevel) {
    const docs = await col.get();
    for (const d of docs.docs) {
      await db.recursiveDelete(d.ref);
    }
  }
  console.log("Done.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

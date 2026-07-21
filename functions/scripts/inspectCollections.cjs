const admin = require("firebase-admin");
const { getFirestore } = require("firebase-admin/firestore");

const PROJECT_ID = "aivy-5c031";

if (!admin.apps.length) {
  admin.initializeApp({ projectId: PROJECT_ID });
}

const db = getFirestore();

async function main() {
  console.log(`Checking Firestore collections for project ${PROJECT_ID}...`);
  const usersCol = db.collection("users");
  const snap = await usersCol.limit(10).get();
  
  if (snap.empty) {
    console.log("No users found in Firestore. The database is empty.");
    return;
  }
  
  console.log(`Found ${snap.size} user documents:`);
  for (const doc of snap.docs) {
    console.log(`- UID: ${doc.id}`);
    const data = doc.data();
    console.log(`  Data:`, JSON.stringify(data, null, 2));
    
    // List subcollections
    const subcols = await doc.ref.listCollections();
    if (subcols.length > 0) {
      console.log(`  Subcollections:`);
      for (const col of subcols) {
        const docCount = (await col.limit(1).get()).size;
        console.log(`    - ${col.id} (${docCount > 0 ? "has docs" : "empty"})`);
      }
    }
  }
}

main().catch(console.error);

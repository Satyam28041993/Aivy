# Mobile se deploy (bina laptop)

GitHub Actions se web app Firebase Hosting pe jaati hai. Phone se 1-tap.

## Step 1 — Service account key (Firebase Console, phone browser)

1. Chrome/Safari me kholo: https://console.firebase.google.com  
2. Project **aivy-5c031** select karo  
3. ⚙️ **Project settings** (gear icon)  
4. Tab **Service accounts**  
5. **Generate new private key** → Confirm → JSON file download hogi  
6. File khol ke **poora JSON text copy** karo (Notes me paste karke theek se select karo)

> Is key ko share mat karo. Sirf GitHub secret me paste karna hai.

## Step 2 — GitHub secret (phone)

1. GitHub app / mobile site → repo **Aivy**  
2. **Settings** → **Secrets and variables** → **Actions**  
3. **New repository secret**  
4. Name (exact): `FIREBASE_SERVICE_ACCOUNT`  
5. Value: jo JSON copy kiya tha → paste → **Add secret**

## Step 3 — Deploy run karo

1. Repo → **Actions** tab  
2. Left me **Deploy Web** workflow select karo  
3. **Run workflow** → branch `main` → Run  
4. **“Also deploy Cloud Functions” checkbox OFF rakho** (sirf web ke liye). ON rakhne pe IAM permission chahiye; Hosting phir bhi succeed hoti hai.  
5. Green tick / Hosting URL: usually `https://aivy-5c031.web.app` — hard refresh karke check karo.

## Agar fail ho

- Secret name galat na ho: `FIREBASE_SERVICE_ACCOUNT`  
- JSON incomplete paste na ho (start `{` end `}`)  
- Firebase pe **Hosting** pehle se enable hona chahiye  
- Functions deploy ke liye service account me Cloud Functions Admin / related roles chahiye (Firebase Admin SDK wala key usually kaafi hota hai)

## Hosting URL

Firebase Console → Hosting → jo default URL dikhe (usually `https://aivy-5c031.web.app`).

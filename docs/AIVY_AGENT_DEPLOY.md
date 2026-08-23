# Aivy Agent — deploy aur keys

Mobile se sab kuch chalane ke liye. Deploy GitHub Actions se hota hai —
laptop ki zaroorat nahi.

---

## 1. Keys — chhoti si khabar: **kuch naya nahi chahiye**

| Key | Kahan rehti hai | Agent ke liye status |
| --- | --- | --- |
| `GEMINI_API_KEY` | Firebase Secret Manager | ✅ **pehle se hai** — `aivyProcess` isi naam ka secret use karta hai, aur naya `aivyAgent` usi ko bind karta hai (`defineSecret("GEMINI_API_KEY")`). Kuch karne ki zaroorat nahi. |
| `FIREBASE_SERVICE_ACCOUNT` | GitHub → repo Secrets | ✅ **pehle se hai** — 17 successful deploy iske saath ho chuke hain |
| `AIVY_RECAPTCHA_SITE_KEY` | GitHub → repo Variables | ✅ pehle se hai (App Check ke liye, optional) |
| `SERPER_API_KEY` | Firestore `app_config/search` | ⚠️ **sirf yahi optional cheez baaki hai** — neeche |

### Web search (optional, 2 minute ka kaam)

`web_search` tool general sawaalon ke liye hai — "printing pe GST kitna lagta hai",
news, prices. Uske bina **baaki sab kuch chalta hai**; sirf research wale sawaal par
Aivy kahegi ki search configured nahi hai.

Chaahein to:

1. [serper.dev](https://serper.dev) par free account (2,500 query free)
2. API key copy karein
3. Firebase Console → **Firestore Database** → Start collection `app_config`
   → Document ID `search` → field `serperApiKey` (string) → key paste → Save

Bas. Function agli call par utha lega — redeploy ki zaroorat nahi.

> Note: `app_config/search` ke liye koi client-side rule nahi hai, isliye ye doc
> **sirf Firebase Console se** banega. App ise padh nahi sakta — sirf Cloud
> Functions (Admin SDK) padhte hain. Yahi sahi hai: key client tak jaani hi nahi chahiye.

---

## 2. Deploy kaise karein (phone se)

GitHub app ya browser me:

**Repo → Actions → "Deploy Web" → Run workflow**

- Branch: `claude/page-voice-process-review-enhkhh` chunein
- **"Also deploy Cloud Functions" ka toggle ON karein** — naya `aivyAgent` isi se jaata hai
- Run workflow

Ye teen cheezein bhejta hai:
1. **Hosting** — web app (naya Aivy tab)
2. **Firestore rules + indexes** — agent ke `agent_drafts` composite index
3. **Functions** — `aivyAgent`, `aivyAgentCommit`, `aivyAgentChats` + baaki sab

~4–6 minute lagte hain. Hosting URL: https://aivy-5c031.web.app

### Deploy se pehle "Checks" dekh lein

Har push par **Checks** workflow apne aap chalta hai:
`flutter analyze` · `flutter test` · functions build · functions test

Dono green hon to hi deploy karein. Isse pata chal jaata hai ki code compile hota hai —
bina laptop ke.

---

## 3. Android APK

**Actions → "Build APK" → Run workflow** (wahi branch chunkar).
Ye web deploy se alag hai; naya screen phone par dekhne ke liye APK chahiye.

---

## 4. ⚠️ Ek zaroori baat — do branch alag-alag ja rahi hain

`claude/git-pull-aro-fxj5gh` branch `main` se **10+ commit aage** hai, aur usne:

- Voice home screen **hata diya** hai
- Gemini Live ka poora stack hata diya hai
- `home_shell.dart` me tabs **7 se 5** kar diye hain

Meri branch usse pehle wale `main` (f670b52) par bani hai, jisme voice home abhi maujood hai,
aur maine tab **7** kar diye (Aivy index 1 par).

**Matlab: dono ko merge karte waqt `home_shell.dart` me conflict aayega.**

Ye abhi koi dikkat nahi hai — dono branch alag-alag theek chalti hain. Par merge se
pehle decide karna hoga:

- Agar voice home hataana final hai → mera Aivy tab index **0** par aa jaayega,
  aur tabs 6 ho jaayenge (Aivy, Chat, WhatsApp, Dashboard, Reports, More)
- Wo merge main kar dunga, bas bata dijiye kaunsa order chahiye

---

## 5. Deploy ke baad kya test karein

Naya **Aivy** tab kholkar:

| Boliye | Hona chahiye |
| --- | --- |
| "aivy yaar main bore ho raha hu" | Normal baat-cheet, koi card nahi |
| "kal 11 baje rohan ke saath meeting hai new labels ke regarding" | Card: **11:00 AM**, client, agenda, reminder |
| Card par "Sahi hai" | "Meeting set ho gayi" + reminder lag jaata hai |
| "rohan ko 50000 ka quotation diya" | Card, confirm karein |
| "kisko quotation diya?" | Upar wala quotation wapas mile |
| "aaj kisko call karna hai?" | Aaj ki list |
| "koi important cheez hai kya?" | Overdue + aaj ka kaam + overdue paisa |
| "printing pe GST kitna?" | Search se jawaab (agar Serper key daali ho) |

Kuch galat lage to **card par hi dikhega** — save hone se pehle. "Badlo" dabakar
normal bhasha me theek kar sakte hain: "12 baje kar do".

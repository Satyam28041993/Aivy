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

## 1b. ⛔ Ek baar ka IAM kaam — pehle deploy par ye zaroori nikla

Pehla deploy (run #18) me **hosting, Firestore rules/indexes aur saare purane
functions successfully chale gaye**. Sirf teen naye function fail hue — aur wo bhi
code par nahi, **IAM policy** par:

```
Failed to set the IAM Policy on the Service .../services/aivyagentcommit
Unable to set the invoker for the IAM policy on:
  aivyAgent, aivyAgentChats, aivyAgentCommit
- You may not have the roles/functions.admin IAM role.
```

**Kyun:** har **naye** callable function ko Firebase publicly-invokable banata hai
(callable khud auth check karta hai — `aivyProcess.ts` me isi ka comment likha hai).
Ye IAM policy set karni padti hai. **Purane** functions ki policy pehle se lagi hai,
isliye unka update bina permission ke ho gaya. Deploy karne wale service account ke
paas naye function par policy lagane ka haq nahi hai.

**Fix — ek baar ka, 2 minute:**

1. [Google Cloud Console → IAM](https://console.cloud.google.com/iam-admin/iam?project=aivy-5c031)
2. Jo service account GitHub Actions use karta hai use dhoondein
   (GitHub secret `FIREBASE_SERVICE_ACCOUNT` wala — IAM list me `...iam.gserviceaccount.com`)
3. Uspar pencil (Edit) → **+ ADD ANOTHER ROLE**
4. **Cloud Run Admin** (`roles/run.admin`) add karein → Save

> Gen2 functions asal me Cloud Run services hain, isliye role `run.admin` hai.
> Agar phir bhi fail ho to **Cloud Functions Admin** (`roles/cloudfunctions.admin`)
> bhi add kar dein.

Uske baad deploy dobara chala dein (neeche wala tareeka) — teenon function chale
jaayenge. Ye sirf **pehli baar** chahiye; aage ke deploys me ye function pehle se
maujood honge.

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

---

## 6. Google — Calendar, Gmail, Sheets, Contacts (naya)

Ab agent ke paas Google ke tools bhi hain. WhatsApp jaan-boojhkar chhoda hai.

| Tool | Kya karta hai | Confirm card? |
| --- | --- | --- |
| `create_meeting` | app ka reminder **+ Google Calendar par event** | haan |
| `create_calendar_event` | personal event calendar par | haan |
| `send_email` | Gmail se mail bhejti hai (mail wo khud likhti hai) | haan |
| `append_sheet_row` | default Google Sheet me row | haan |
| `list_calendar_events` | "kal calendar par kya hai" | nahi (padhna hai) |
| `list_recent_emails` | "koi mail aaya kya" | nahi |
| `find_contact` | naam se email/phone | nahi |

Jo cheez bahar jaati hai (mail, calendar invite, sheet) wo **sirf card confirm karne
par** jaati hai — waise hi jaise quotation ya payment.

### ⚠️ Ye sirf **Android app** me chalta hai

Google ke REST API device wali Google sign-in se chalte hain, jo web build me
available nahi hai (`FirebaseSession.googleWorkspaceAuthHeaders()` web par
`UnsupportedError` phenkti hai). Matlab:

- **Web (aivy-5c031.web.app)** — baaki sab kuch chalta hai; calendar/mail/sheet wale
  tools Aivy khud bata degi ki "Android app chahiye"
- **Android APK** — sab chalta hai

Isliye ab **APK build karna zaroori ho gaya**: Actions → "Build APK" → Run workflow.

### Phone par ek baar permission deni hai

Naye Aivy tab me upar-right me ek **cloud icon** hai:

- ☁️ (grey, cross) — Google juda nahi hai → tap karke permission de dijiye
- ☁️ (hara, tick) — juda hua hai, sab chaalu

Ya purana raasta: **More → Allow Google extras**.

### Token kahan rehta hai

Kahin store nahi hota. Har message ke saath app apna Google access token function ko
bhejti hai, function usi turn me Google se baat karta hai, aur baat khatam. Firestore
me nahi likha jaata, log me nahi jaata, aur Google use ~1 ghante me khud expire kar
deta hai. Draft ke saath bhi save nahi hota — isliye confirm karte waqt app token
dobara bhejti hai.

### Sheet ka ID

`append_sheet_row` default sheet use karta hai — wahi jo pehle se
`users/{uid}/meta/google_prefs` → `defaultSpreadsheetId` me set hota hai (More →
Google settings). Set nahi hai to Aivy maang legi.

### Test karne ke liye (APK par)

| Boliye | Hona chahiye |
| --- | --- |
| "kal 11 baje rohan ke saath meeting hai" → confirm | reminder + "Google Calendar par bhi daal diya" |
| "kal calendar par kya hai?" | Google Calendar ke events |
| "koi mail aaya kya?" | inbox ke last 8 mail |
| "rohan ko mail bhej do ki quotation bhej diya hai" | mail ka card — padhkar confirm |
| "rohan ka email kya hai?" | contacts se address |

---

## 7. Google Maps — Places + Routes (naya)

Ab do aur tools hain, dono **padhne wale** (koi card nahi, kuch save nahi hota):

| Boliye | Tool | Milega |
| --- | --- | --- |
| "paas me koi printing press hai?" | `find_places` | naam, address, phone, rating, abhi khula hai ya nahi, Maps ka link |
| "Sharma Printers Kanpur ka address?" | `find_places` | wahi |
| "Lucknow kitna door hai, kitna time lagega?" | `get_directions` | km + **traffic ke saath asli ETA** + Maps link |
| "bike se kitna time?" | `get_directions` | two-wheeler ka time |

"Paas me" ka matlab aapke shehar ke aas-paas hota hai — wo shehar aapki remembered
facts se aata hai. Ek baar bol dijiye "main Kanpur me hoon", Aivy `remember_fact` se
yaad rakh legi aur uske baad har search wahin se hogi.

### ⚠️ Ye Android aur web — dono par chalega

Maps ke liye aapka Google account nahi, **project ki API key** lagti hai. Isliye
Gmail/Calendar wali Android-only wali baat yahan lagu nahi hoti.

### Key kaise banayein (10 minute, ek baar)

1. [Google Cloud Console → Credentials](https://console.cloud.google.com/apis/credentials?project=aivy-5c031)
   (project `aivy-5c031` hi chuna hona chahiye)
2. **+ CREATE CREDENTIALS → API key** → key copy kar lijiye
3. Us key par **Edit** → **API restrictions** → "Restrict key" → sirf ye do chunein:
   - **Places API (New)**
   - **Routes API**
   → Save
   > Application restriction "None" hi rehne dijiye — key server par use hoti hai,
   > kisi browser ya app se nahi.
4. Dono API enable karni hongi (agar pehle se nahi hain):
   - [Places API (New) enable](https://console.cloud.google.com/apis/library/places.googleapis.com?project=aivy-5c031)
   - [Routes API enable](https://console.cloud.google.com/apis/library/routes.googleapis.com?project=aivy-5c031)
5. **Billing** on karni padegi — Cloud Console → Billing → card add. Ye Google ki
   shart hai, kharch ki wajah se nahi (neeche dekhiye).
6. Key ko app tak pahunchaiye — Firebase Console → **Firestore Database** →
   collection `app_config` → document `maps` → field **`mapsApiKey`** (string) →
   key paste → Save

Bas. Redeploy ki zaroorat nahi — function 5 minute ke andar khud utha lega.

### Kharch — practically zero

Google har mahine **$200 ka free credit** deta hai Maps Platform par. Iss app ke
hisaab se:

- Text Search (Places New, essentials) ≈ **$32 per 1000** requests
- Compute Routes ≈ **$5 per 1000** requests

Matlab free credit me har mahine **~6000 place searches** ya **~40,000 route
queries** aa jaate hain. Ek aadmi ke business assistant me itna use hona mushkil
hai. Phir bhi safety ke liye: Cloud Console → Billing → **Budgets & alerts** me
₹500 ka alert laga dijiye, aur upar wali API restriction laga hi rakhiye taaki key
kahin aur use na ho sake.

### Key kahan rehti hai

App me kabhi nahi. Sirf Firestore `app_config/maps` me, jise **koi client padh nahi
sakta** — na app, na browser; sirf Cloud Functions (Admin SDK). Wahi tarika jo
`serperApiKey` ke liye use hota hai. Isiliye ye document **Firebase Console se hi**
banega, app se nahi.

### Key daalne se pehle kya hoga

Kuch toota nahi — Aivy saaf-saaf keh degi ki "Maps abhi set nahi hai", aur baaki sab
kaam waise hi chalta rahega.

---

## 8. Live location (naya)

Ab har message ke saath app phone ki location bhejti hai (agar permission ho).
Isse:

| Boliye | Pehle | Ab |
| --- | --- | --- |
| "paas me koi printing press hai?" | shehar poochhti thi | jahan aap khade hain, wahin se |
| "yahan se Saphale station kitni door hai?" | "kahan se?" | seedha jawaab |
| "main abhi kahan hoon?" | "pata nahi" | address + Maps link |

**Permission:** Aivy tab pehli baar kholne par Android khud poochhega. Mana kar dein
to kuch tootega nahi — bas jagah ka naam poochhna padega, jaisa pehle tha. Baad me
dena ho: Settings → Apps → Aivy → Permissions → Location.

**Location store nahi hoti.** Google token ki tarah, sirf usi turn me use hoti hai —
Firestore me nahi likhi jaati, log me nahi jaati.

Agar aap khud jagah ka naam bol dein ("Lucknow me kya hai"), to wo naam jeetega —
live location tabhi use hoti hai jab aap koi jagah na batayein.

### "Main kahan hoon" ka address — ek aur API (optional)

Coordinates se address banane ke liye **Geocoding API** chahiye. Uske bina bhi
sab kuch chalta hai — "paas me", doori, ETA — sirf `main kahan hoon` ka jawaab
address ki jagah coordinates + Maps link me aayega.

Chahein to:
1. [Geocoding API enable karein](https://console.cloud.google.com/apis/library/geocoding-backend.googleapis.com?project=aivy-5c031)
2. [Credentials](https://console.cloud.google.com/apis/credentials?project=aivy-5c031) → apni Maps key → Edit → **API restrictions** me **Geocoding API** bhi tick → Save

Kharch: ~$5 per 1000 — free credit me kuch nahi lagega.

### Ye APK ka change hai

Location app ke andar se aati hai, isliye iske liye **naya APK chahiye** (functions
deploy kaafi nahi).


---

## 9. Apni jagahein save karna (naya)

Kahin bhi khade hokar boliye — **"is location ko Rohan Office ke naam se save karlo"**.
Card aayega jisme naam aur address dikhega; confirm kijiye, save ho gaya.

Uske baad:

| Boliye | Milega |
| --- | --- |
| "Rohan Office ka link bhejo" | Maps ka link + address + **yahan se kitni door** |
| "Rohan Office kitni door hai?" | km + traffic ke saath ETA |
| "kaun kaun si jagah save hai?" | poori list |
| "Rohan Office hata do" | hat jaayegi |

Kuch baatein:

- Naam kaise bhi likhiye — "rohan office", "Rohan Office", "ROHAN  OFFICE" — ek hi
  jagah milegi. Aadha naam bhi chalega ("mehta") jab tak sirf ek jagah us naam se
  match kare; do match hue to Aivy poochh legi, apne se andaaza nahi lagayegi.
- Wahi naam dobara save karenge to **jagah badal jaayegi**, dusri nahi banegi.
  Card par pehle hi likha aayega ki purani jagah badlegi.
- Address ke liye Geocoding API chahiye. Na ho to bhi jagah save hoti hai — bas
  card par address ki jagah coordinates dikhenge.
- Ye jagahein "Fresh start" me mit jaati hain, kyunki ye aapka business data hai.

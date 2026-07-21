# Aivy Google Cloud Voice (STT + TTS) — setup guide

This app uses **Google Cloud Speech-to-Text** and **Text-to-Speech** from **Firebase Cloud Functions** so API keys and service-account private keys **never ship inside the Flutter APK**.

Project: **aivy-5c031**  
Service account (example): **aivy-voice-service@aivy-5c031.iam.gserviceaccount.com**

---

## 1. Enable APIs (you already did)

In Google Cloud Console for `aivy-5c031`:

- Cloud Speech-to-Text API  
- Cloud Text-to-Speech API  

---

## 2. Service account JSON (two supported patterns)

### Pattern A — Recommended: IAM on the Firebase Functions runtime (no JSON in Firebase)

1. In GCP **IAM**, find the Cloud Functions v2 runtime identity for this project, typically:
   - `{project-number}-compute@developer.gserviceaccount.com` (default compute SA used by many Gen2 functions), **or**
   - The custom runtime service account if you configured one on the function.
2. Grant that principal:
   - `roles/speech.client`
   - `roles/texttospeech.user`
3. Deploy functions. The code uses **Application Default Credentials** (`new SpeechClient()` / `new TextToSpeechClient()`).

No JSON file is uploaded to Firebase in this pattern.

### Pattern B — Dedicated voice service account JSON (optional)

Use this if you want isolation on **`aivy-voice-service@...`**.

1. In GCP **IAM & Admin → Service accounts**, select `aivy-voice-service`.
2. **Keys → Add key → JSON** and download the file once.
3. **Do not commit** the JSON to git.
4. For Cloud Functions, set the **entire JSON string** as the environment variable **`GOOGLE_VOICE_SA_JSON`** on the deployed functions (Console: Cloud Functions → function → Edit → Runtime environment variables). The Functions code parses it and passes `credentials` to the Google clients.

> Storing multi-line JSON in env vars is awkward; paste minified one-line JSON or use Secret Manager + mount (advanced).

---

## 3. Flutter app behaviour

- **Mic hold**: records M4A (AAC), uploads to Storage, `aivyProcess` transcribes with **Google STT first**, then falls back to **Gemini** if STT fails.
- **Hands-free (equalizer icon)**: continuous recording, **silence detection** via amplitude, then same upload + `aivyProcess` pipeline.
- **Assistant voice**: callable **`googleSpeechSynthesize`** returns an MP3 URL stored under `users/{uid}/tts/`. The URL is saved on the assistant message as `aivyData.ttsAudioUrl` in Firestore.
- **Settings** (SharedPreferences keys, toggles can be wired in UI later):
  - `aivy_assistant_voice_replies` — generate TTS MP3 for assistant replies (default **true**).
  - `aivy_auto_play_assistant_voice` — autoplay when a new assistant message includes `ttsAudioUrl` (default **true**).

---

## 4. Deploy Cloud Functions

From the `functions` folder:

```bash
npm install
npm run build
firebase deploy --only functions
```

New / updated exports:

- `googleSpeechSynthesize` — authenticated callable; text → MP3 URL.
- `aivyProcess` — voice path tries **Google STT** before Gemini.

Ensure **`GEMINI_API_KEY`** remains configured for the main Aivy reasoning path.

---

## 5. Android notes

- `RECORD_AUDIO` is already declared; the app uses `permission_handler` at runtime.
- Hands-free + hold-to-record use the **`record`** plugin (AAC-LC in M4A, 44.1 kHz mono) for compatibility with Google **MP4_AAC** STT.

---

## 6. Security reminder

Never embed the service account JSON inside the Flutter client. All Google Cloud voice calls run **only** in trusted backend (Cloud Functions).

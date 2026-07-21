# Aivy (Phase 2 Agent Activation)

Aivy is a personal AI companion app built with Flutter, Firebase, and OpenAI.

Phase 2 includes:

- Chat-first UI
- Secure OpenAI processing via Firebase Cloud Functions
- Structured AI output (`summary`, `keyPoints`, `actionItems`, follow-ups, reminders)
- Agent activation: automatic task + reminder creation
- App-open reminder trigger flow (pending -> triggered)
- Dashboard focused on execution (due today, overdue, priorities, upcoming reminders)

## Current Architecture

- `lib/features/bootstrap`: Firebase initialization + anonymous auth gate
- `lib/features/chat`: chat UI, repository, function service, AI response models
- `lib/features/tasks`: task models
- `lib/features/reminders`: reminder models + time parser
- `lib/features/dashboard`: action-centric structured view
- `lib/features/home`: tab shell (Chat + Dashboard)
- `lib/core`: app config and theme
- `functions/src`: secure callable AI processing endpoint

## Firebase Setup

1. Create a Firebase project.
2. Enable **Authentication > Anonymous** sign-in.
3. Create Firestore database.
4. Add Firebase app configs for your platforms:
   - Android: `google-services.json`
   - iOS: `GoogleService-Info.plist`
5. Follow FlutterFire installation steps for your target platform.
6. Deploy Firestore rules + indexes from this repo:

```bash
firebase deploy --only firestore
```

7. Set OpenAI secret for Cloud Functions:

```bash
firebase functions:secrets:set OPENAI_API_KEY
```

8. Deploy functions:

```bash
cd functions
npm install
npm run build
firebase deploy --only functions
```

## Run

```bash
flutter pub get
flutter run
```

The app uses Firebase Authentication plus `cloud_functions` to call the private
`aivyProcess` callable function, so no public Function URL or `allUsers` IAM
binding is required.

## Firestore Data Shape (Phase 2)

- `users/{uid}/messages`:
  - `role`, `text`, `entryId`, `createdAt`, `createdAtMs`
- `users/{uid}/entries`:
  - `source`, `rawInput`, `status`, `contextType`, `summary`, `keyPoints`,
    `assistantReply`, `actionItems`, `followUpSuggestions`,
    `reminderSuggestions`, `createdAt`, `createdAtMs`, `updatedAt`
- `users/{uid}/tasks`:
  - `title`, `sourceEntryId`, `createdAt`, `createdAtMs`,
    `dueDate`, `dueDateMs`, `status`, `priority`
- `users/{uid}/reminders`:
  - `message`, `scheduledTime`, `scheduledTimeMs`,
    `relatedTaskId`, `sourceEntryId`, `status`, `priority`,
    `createdAt`, `createdAtMs`, `triggeredAt`

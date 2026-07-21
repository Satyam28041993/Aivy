/// Canonical label for the primary human operator (used in UI / analytics).
///
/// Firestore paths always use [FirebaseAuth.currentUser.uid] so they match
/// `firestore.rules` (`request.auth.uid == userId`). To use this exact string
/// as a document path, create a Firebase Auth user with this UID via the Admin
/// SDK, or sign in with Google: the same Google account always yields the same
/// Firebase `uid` across devices.
const String kSatyamMainUserLabel = 'satyam_main_user';

/// Optional Web OAuth client ID for [GoogleSignIn] (`xxx.apps.googleusercontent.com`).
/// Pass at build time: `--dart-define=AIVY_WEB_GOOGLE_CLIENT_ID=...`
const String kWebGoogleClientId = String.fromEnvironment(
  'AIVY_WEB_GOOGLE_CLIENT_ID',
  defaultValue: '',
);
